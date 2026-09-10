// SPDX-FileCopyrightText: 2026 JustPav
// SPDX-FileCopyrightText: 2026 SmoothTeam
//
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

use std::collections::VecDeque;
use std::os::raw::c_void;
use std::path::PathBuf;

use composefs::tree::FileSystem;

use uuid::Uuid;

use upac_abi::HookMessageFn;
use upac_abi::error::ErrorKind;
use upac_abi::hook::CancelToken;
use upac_abi::package::CPackageInfo;
use upac_abi::request::CFilesRequest;
use upac_abi::{DiffFileSource, FileDiffKind};

use upac_types::TmpPath;
use upac_types::hook::Message;
use upac_types::states::FilesStateId;
use upac_types::traits::MessageHook;

use upac_macro::ContextValue;

use self::apply::ApplyFileStage;
use self::checkout::CheckoutStage;
use self::commit::CommitTransactionStage;
use self::open::OpenTransactionStage;
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

pub use self::error::FilesError;

mod apply;
mod checkout;
mod commit;
mod error;
mod open;
mod swap;

pub(crate) struct RequestedFileOperation {
    pub kind: FileDiffKind,
    pub scope: DiffFileSource,
}
pub(crate) struct RequestedFilePackage {
    pub name: String,
    pub arch: String,
    pub arch_sub: Option<String>,
}

#[derive(ContextValue)]
pub(crate) struct NewPrefixDigest(pub String);

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

pub(crate) struct FileProgress {
    pub pending: VecDeque<String>,
    pub total: u64,
}

pub(crate) struct WorkingState {
    pub tree: FileSystem<ObjectID>,
    pub database: MemoryDatabase,
}

pub(crate) struct ApplyTarget {
    pub uuid: Uuid,
    pub config_upper_dir: PathBuf,
}

pub struct FilesPackage<'a> {
    pub name: &'a str,
    pub arch: &'a str,
    pub arch_sub: Option<&'a str>,
}

impl<'a> TryFrom<&'a CPackageInfo> for FilesPackage<'a> {
    type Error = ErrorKind;

    fn try_from(info: &'a CPackageInfo) -> Result<Self, ErrorKind> {
        unsafe { info.validate()? };

        Ok(FilesPackage {
            name: (&info.name).try_into()?,
            arch: (&info.arch).try_into()?,
            arch_sub: (&info.arch_sub).try_into()?,
        })
    }
}

pub struct FilesData<'a> {
    pub scope: DiffFileSource,

    pub files: Vec<&'a str>,
    pub file_kind: FileDiffKind,
    pub file_package: FilesPackage<'a>,

    pub boot_plugin: &'a str,

    pub tmp_path: &'a str,

    pub subject: &'a str,
    pub message: Option<&'a str>,

    pub hook_message: Option<HookMessageFn>,
    pub hook_message_context: *mut c_void,

    pub cancel_token: &'a CancelToken,
}

impl<'a> TryFrom<&'a CFilesRequest> for FilesData<'a> {
    type Error = ErrorKind;

    fn try_from(request: &'a CFilesRequest) -> Result<Self, ErrorKind> {
        unsafe { request.validate()? };

        let file_package = unsafe { request.file_package.as_ref() }.ok_or(ErrorKind::InvalidEntry)?;

        let cancel_token = unsafe { &*request.base.cancel_token };

        Ok(FilesData {
            scope: request.scope,

            files: Vec::try_from(&request.files)?,
            file_kind: request.file_kind,
            file_package: FilesPackage::try_from(file_package)?,

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

pub fn run(data: FilesData) -> Result<(), (FilesStateId, FilesError)> {
    let deploy = Deploy::new(DeployMode::ReadWrite).map_err(|error| (FilesStateId::Setup, FilesError::from(error)))?;

    let mut context = Context::new();
    context.put(deploy);
    context.put(
        data.files
            .iter()
            .map(|path| (*path).to_owned())
            .collect::<Vec<String>>(),
    );
    context.put(RequestedFileOperation {
        kind: data.file_kind,
        scope: data.scope,
    });
    context.put(RequestedFilePackage {
        name: data.file_package.name.to_owned(),
        arch: data.file_package.arch.to_owned(),
        arch_sub: data.file_package.arch_sub.map(str::to_owned),
    });
    context.put(TmpPath(data.tmp_path.to_owned()));
    context.put(CommitInfo {
        subject: data.subject.to_owned(),
        message: data.message.map(str::to_owned),
    });
    context.put(RequestedBootPlugin(data.boot_plugin.to_owned()));
    context.put(Box::new(Message::new(data.hook_message, data.hook_message_context)) as Box<dyn MessageHook>);

    let orchestrator = assemble();

    let result = run_mutating!(orchestrator, context, data.cancel_token, FilesStateId, FilesError);

    data.cancel_token.reset();

    result
}

fn assemble() -> SequentialOrchestrator<FilesError> {
    SequentialOrchestrator::new(vec![
        Box::new(HookStage {
            trigger: PipelineTrigger::pre(Operation::Files),
        }),
        Box::new(OpenTransactionStage),
        Box::new(ApplyFileStage),
        Box::new(CommitTransactionStage),
        Box::new(CheckoutStage),
        Box::new(SwapStage),
        Box::new(HookStage {
            trigger: PipelineTrigger::post(Operation::Files),
        }),
        Box::new(RetentionStage),
    ])
}
