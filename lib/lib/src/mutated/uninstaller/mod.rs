// SPDX-FileCopyrightText: 2026 JustPav
// SPDX-FileCopyrightText: 2026 SmoothTeam
//
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

use std::collections::VecDeque;
use std::os::raw::c_void;

use composefs::tree::FileSystem;

use uuid::Uuid;

use upac_abi::HookMessageFn;
use upac_abi::error::ErrorKind;
use upac_abi::hook::CancelToken;
use upac_abi::package::CPackageInfo;
use upac_abi::request::CUninstallRequest;

use upac_types::hook::Message;
use upac_types::package::PackageEntry;
use upac_types::states::UninstallStateId;
use upac_types::traits::MessageHook;
use upac_types::{TmpPath, UninstallPackagesTargets};

use upac_macro::ContextValue;

use self::checkout::CheckoutStage;
use self::commit::CommitTransactionStage;
use self::merge::MergeStage;
use self::open::OpenTransactionStage;
use self::preparation::PreparationStage;
use self::remove::RemovePackageStage;
use self::swap::SwapStage;

use crate::composefs::repository::ObjectID;
use crate::database::MemoryDatabase;
use crate::deploy::retention::RetentionStage;
use crate::deploy::{Deploy, DeployMode};
use crate::orchestrator::context::Context;
use crate::orchestrator::{Orchestrator, SequentialOrchestrator, run_mutating};
use crate::plugin::boot::BootPlugin;
use crate::scripts::HookStage;
use crate::scripts::pipeline::{Operation, PipelineTrigger};

pub use self::error::UninstallError;

mod checkout;
mod commit;
mod error;
mod merge;
mod open;
mod preparation;
mod remove;
mod swap;

#[derive(ContextValue)]
pub(crate) struct PackageUuidsToRemove(pub Vec<Uuid>);

pub(crate) struct NewState {
    pub prefix_digest: String,
    pub removed_config_paths: Vec<String>,
}

pub(crate) struct CommitInfo {
    pub subject: String,
    pub message: Option<String>,
}

#[derive(ContextValue)]
pub(crate) struct Purge(pub bool);

#[derive(ContextValue)]
pub(crate) struct RequestedBootPlugin(pub String);
pub(crate) struct ResolvedBootEntry {
    pub plugin: BootPlugin,
    pub entry_name: String,
}

pub(crate) struct RemoveProgress {
    pub pending: VecDeque<Uuid>,
    pub total: u64,
}

pub(crate) struct WorkingState {
    pub tree: FileSystem<ObjectID>,
    pub database: MemoryDatabase,
    pub removed_config_paths: Vec<String>,
}

pub struct UninstallPackage<'a> {
    pub name: &'a str,
    pub arch: &'a str,
    pub arch_sub: Option<&'a str>,
}

impl<'a> TryFrom<&'a CPackageInfo> for UninstallPackage<'a> {
    type Error = ErrorKind;

    fn try_from(info: &'a CPackageInfo) -> Result<Self, ErrorKind> {
        unsafe { info.validate()? };

        Ok(UninstallPackage {
            name: (&info.name).try_into()?,
            arch: (&info.arch).try_into()?,
            arch_sub: (&info.arch_sub).try_into()?,
        })
    }
}

pub struct UninstallData<'a> {
    pub packages: Vec<UninstallPackage<'a>>,

    pub purge: bool,

    pub boot_plugin: &'a str,

    pub tmp_path: &'a str,

    pub subject: &'a str,
    pub message: Option<&'a str>,

    pub hook_message: Option<HookMessageFn>,
    pub hook_message_context: *mut c_void,

    pub cancel_token: &'a CancelToken,
}

impl<'a> TryFrom<&'a CUninstallRequest> for UninstallData<'a> {
    type Error = ErrorKind;

    fn try_from(request: &'a CUninstallRequest) -> Result<Self, ErrorKind> {
        unsafe { request.validate()? };

        let cancel_token = unsafe { &*request.base.cancel_token };

        Ok(UninstallData {
            packages: Vec::try_from(&request.packages)?,

            purge: request.purge,

            boot_plugin: (&request.boot_plugin).try_into()?,

            tmp_path: (&request.tmp_path).try_into()?,

            subject: (&request.subject).try_into()?,
            message: (&request.message).try_into()?,

            hook_message: request.base.on_hook,
            hook_message_context: request.base.hook_ctx,

            cancel_token,
        })
    }
}

pub fn run(data: UninstallData) -> Result<(), (UninstallStateId, UninstallError)> {
    let deploy =
        Deploy::new(DeployMode::ReadWrite).map_err(|error| (UninstallStateId::Setup, UninstallError::from(error)))?;

    let targets = UninstallPackagesTargets(
        data.packages
            .iter()
            .map(|package| PackageEntry {
                name: package.name.to_owned(),
                arch: package.arch.to_owned(),
                arch_sub: package.arch_sub.map(str::to_owned),
            })
            .collect(),
    );

    let mut context = Context::new();
    context.put(targets);
    context.put(deploy);
    context.put(TmpPath(data.tmp_path.to_owned()));
    context.put(CommitInfo {
        subject: data.subject.to_owned(),
        message: data.message.map(str::to_owned),
    });
    context.put(RequestedBootPlugin(data.boot_plugin.to_owned()));
    context.put(Purge(data.purge));
    context.put(Box::new(Message::new(data.hook_message, data.hook_message_context)) as Box<dyn MessageHook>);

    let orchestrator = assemble();

    let result = run_mutating!(
        orchestrator,
        context,
        data.cancel_token,
        UninstallStateId,
        UninstallError
    );

    data.cancel_token.reset();

    result
}

fn assemble() -> SequentialOrchestrator<UninstallError> {
    SequentialOrchestrator::new(vec![
        Box::new(HookStage {
            trigger: PipelineTrigger::pre(Operation::Uninstall),
        }),
        Box::new(PreparationStage),
        Box::new(OpenTransactionStage),
        Box::new(RemovePackageStage),
        Box::new(CommitTransactionStage),
        Box::new(MergeStage),
        Box::new(CheckoutStage),
        Box::new(SwapStage),
        Box::new(HookStage {
            trigger: PipelineTrigger::declarative(Operation::Uninstall),
        }),
        Box::new(HookStage {
            trigger: PipelineTrigger::post(Operation::Uninstall),
        }),
        Box::new(RetentionStage),
    ])
}
