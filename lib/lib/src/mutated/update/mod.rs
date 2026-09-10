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
use upac_abi::request::CUpdateRequest;

use upac_types::TmpPath;
use upac_types::decoder::DeclarativeTrigger;
use upac_types::hook::Message;
use upac_types::package::PackageTemp;
use upac_types::states::UpdateStateId;
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

pub use self::error::UpdateError;

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
    pub removed_config_paths: Vec<String>,
}

pub(crate) struct CommitInfo {
    pub subject: String,
    pub message: Option<String>,
}

#[derive(ContextValue)]
pub(crate) struct RequestedBootPlugin(pub String);
pub(crate) struct ResolvedBootEntry {
    pub plugin: BootPlugin,
    pub entry_name: String,
}

#[derive(ContextValue)]
pub(crate) struct AllowDowngrade(pub bool);
#[derive(ContextValue)]
pub(crate) struct AllowConflictFiles(pub bool);

pub(crate) struct UnpackState {
    pub pending_paths: VecDeque<String>,
    pub unpacker: PackageUnpacker,
}

pub(crate) struct ImportProgress {
    pub pending: VecDeque<(PackageTemp, DeclarativeTrigger)>,
    pub total: u64,
}

pub(crate) struct ImportedState {
    pub tree: FileSystem<ObjectID>,
    pub config_defaults: FileSystem<ObjectID>,
    pub database: MemoryDatabase,
    pub removed_config_paths: Vec<String>,
}

pub struct UpdateData<'a> {
    pub packages: Vec<&'a str>,

    pub boot_plugin: &'a str,

    pub allow_downgrade: bool,
    pub allow_conflict_files: bool,

    pub tmp_path: &'a str,

    pub subject: &'a str,
    pub message: Option<&'a str>,

    pub hook_message: Option<HookMessageFn>,
    pub hook_message_context: *mut c_void,

    pub cancel_token: &'a CancelToken,
}

impl<'a> TryFrom<&'a CUpdateRequest> for UpdateData<'a> {
    type Error = ErrorKind;

    fn try_from(request: &'a CUpdateRequest) -> Result<Self, ErrorKind> {
        unsafe { request.validate()? };

        let cancel_token = unsafe { &*request.base.cancel_token };

        Ok(UpdateData {
            packages: Vec::try_from(&request.packages)?,

            boot_plugin: (&request.boot_plugin).try_into()?,

            allow_downgrade: request.allow_downgrade,
            allow_conflict_files: request.allow_conflict_files,

            tmp_path: (&request.tmp_path).try_into()?,

            subject: (&request.subject).try_into()?,
            message: (&request.message).try_into()?,

            hook_message: request.base.on_hook,
            hook_message_context: request.base.hook_ctx,

            cancel_token,
        })
    }
}

pub fn run(data: UpdateData) -> Result<(), (UpdateStateId, UpdateError)> {
    let deploy =
        Deploy::new(DeployMode::ReadWrite).map_err(|error| (UpdateStateId::Setup, UpdateError::from(error)))?;
    let unpacker = PackageUnpacker::new()
        .map_err(|error| (UpdateStateId::Setup, UpdateError::from(CommonError::Decoder(error))))?;

    let total_packages = data.packages.len() as u64;

    let mut context = Context::new();
    context.put(deploy);
    context.put(UnpackState {
        pending_paths: data.packages.iter().map(|path| (*path).to_owned()).collect(),
        unpacker,
    });
    context.put(ImportProgress {
        pending: VecDeque::new(),
        total: total_packages,
    });
    context.put(TmpPath(data.tmp_path.to_owned()));
    context.put(CommitInfo {
        subject: data.subject.to_owned(),
        message: data.message.map(str::to_owned),
    });
    context.put(RequestedBootPlugin(data.boot_plugin.to_owned()));
    context.put(AllowDowngrade(data.allow_downgrade));
    context.put(AllowConflictFiles(data.allow_conflict_files));
    context.put(Box::new(Message::new(data.hook_message, data.hook_message_context)) as Box<dyn MessageHook>);

    let orchestrator = assemble();

    let result = run_mutating!(orchestrator, context, data.cancel_token, UpdateStateId, UpdateError);

    data.cancel_token.reset();

    result
}

fn assemble() -> SequentialOrchestrator<UpdateError> {
    SequentialOrchestrator::new(vec![
        Box::new(HookStage {
            trigger: PipelineTrigger::pre(Operation::Update),
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
            trigger: PipelineTrigger::declarative(Operation::Update),
        }),
        Box::new(HookStage {
            trigger: PipelineTrigger::post(Operation::Update),
        }),
        Box::new(RetentionStage),
    ])
}
