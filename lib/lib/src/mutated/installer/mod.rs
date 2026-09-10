// SPDX-FileCopyrightText: 2026 JustPav
// SPDX-FileCopyrightText: 2026 SmoothTeam
//
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

use std::collections::VecDeque;
use std::os::raw::c_void;

use composefs::tree::FileSystem;

use upac_abi::HookMessageFn;
use upac_abi::error::ErrorKind;
use upac_abi::hook::CancelToken;
use upac_abi::request::CInstallRequest;

use upac_types::TmpPath;
use upac_types::decoder::DeclarativeTrigger;
use upac_types::hook::Message;
use upac_types::package::PackageTemp;
use upac_types::states::InstallStateId;
use upac_types::traits::MessageHook;

use upac_macro::ContextValue;

use self::checkout::CheckoutStage;
use self::commit::CommitTransactionStage;
use self::fetching::FetchingStage;
use self::import::ImportPackageStage;
use self::merge::MergeStage;
use self::open::OpenTransactionStage;
use self::preparation::PreparationStage;
use self::swap::SwapStage;

use crate::composefs::repository::ObjectID;
use crate::database::MemoryDatabase;
use crate::deploy::retention::RetentionStage;
use crate::deploy::{Deploy, DeployMode};
use crate::errors::CommonError;
use crate::orchestrator::context::Context;
use crate::orchestrator::{Orchestrator, SequentialOrchestrator, run_mutating};
use crate::plugin::boot::BootPlugin;
use crate::plugin::decoder::unpack::PackageUnpacker;
use crate::scripts::HookStage;
use crate::scripts::pipeline::{Operation, PipelineTrigger};

pub use self::error::InstallError;

mod checkout;
mod commit;
mod error;
mod fetching;
mod import;
mod merge;
mod open;
mod preparation;
mod swap;

pub(crate) struct NewState {
    pub prefix_digest: String,
    pub config_defaults: FileSystem<ObjectID>,
}

pub(crate) struct CommitInfo {
    pub subject: String,
    pub message: Option<String>,
    pub allow_conflict_files: bool,
}

#[derive(ContextValue)]
pub(crate) struct RequestedBootPlugin(pub String);
pub(crate) struct ResolvedBootEntry {
    pub plugin: BootPlugin,
    pub entry_name: String,
}

pub(crate) struct UnpackState {
    pub pending_paths: VecDeque<String>,
    pub unpacker: PackageUnpacker,
}

pub(crate) struct InstallProgress {
    pub pending: VecDeque<(PackageTemp, DeclarativeTrigger)>,
    pub total: u64,
}

pub(crate) struct ImportedState {
    pub tree: FileSystem<ObjectID>,
    pub config_defaults: FileSystem<ObjectID>,
    pub database: MemoryDatabase,
}

pub struct InstallData<'a> {
    pub packages: Vec<&'a str>,

    pub allow_conflict_files: bool,

    pub boot_plugin: &'a str,

    pub tmp_path: &'a str,

    pub subject: &'a str,
    pub message: Option<&'a str>,

    pub hook_message: Option<HookMessageFn>,
    pub hook_message_context: *mut c_void,

    pub cancel_token: &'a CancelToken,
}

impl<'a> TryFrom<&'a CInstallRequest> for InstallData<'a> {
    type Error = ErrorKind;

    fn try_from(request: &'a CInstallRequest) -> Result<Self, ErrorKind> {
        unsafe { request.validate()? };

        let cancel_token = unsafe { &*request.base.cancel_token };

        Ok(InstallData {
            packages: Vec::try_from(&request.packages)?,

            allow_conflict_files: request.allow_conflict_files,

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

pub fn run(data: InstallData) -> Result<(), (InstallStateId, InstallError)> {
    let deploy =
        Deploy::new(DeployMode::ReadWrite).map_err(|error| (InstallStateId::Setup, InstallError::from(error)))?;
    let unpacker = PackageUnpacker::new()
        .map_err(|error| (InstallStateId::Setup, InstallError::from(CommonError::Decoder(error))))?;

    let total_packages = data.packages.len() as u64;

    let mut context = Context::new();
    context.put(deploy);
    context.put(UnpackState {
        pending_paths: data.packages.iter().map(|path| (*path).to_owned()).collect(),
        unpacker,
    });
    context.put(InstallProgress {
        pending: VecDeque::new(),
        total: total_packages,
    });
    context.put(TmpPath(data.tmp_path.to_owned()));
    context.put(CommitInfo {
        subject: data.subject.to_owned(),
        message: data.message.map(str::to_owned),
        allow_conflict_files: data.allow_conflict_files,
    });
    context.put(RequestedBootPlugin(data.boot_plugin.to_owned()));
    context.put(Box::new(Message::new(data.hook_message, data.hook_message_context)) as Box<dyn MessageHook>);

    let orchestrator = assemble();

    let result = run_mutating!(orchestrator, context, data.cancel_token, InstallStateId, InstallError);

    data.cancel_token.reset();

    result
}

fn assemble() -> SequentialOrchestrator<InstallError> {
    SequentialOrchestrator::new(vec![
        Box::new(HookStage {
            trigger: PipelineTrigger::pre(Operation::Install),
        }),
        Box::new(FetchingStage),
        Box::new(PreparationStage),
        Box::new(OpenTransactionStage),
        Box::new(ImportPackageStage),
        Box::new(CommitTransactionStage),
        Box::new(MergeStage),
        Box::new(CheckoutStage),
        Box::new(SwapStage),
        Box::new(HookStage {
            trigger: PipelineTrigger::declarative(Operation::Install),
        }),
        Box::new(HookStage {
            trigger: PipelineTrigger::post(Operation::Install),
        }),
        Box::new(RetentionStage),
    ])
}
