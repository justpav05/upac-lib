// SPDX-FileCopyrightText: 2026 JustPav
// SPDX-FileCopyrightText: 2026 SmoothTeam
//
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

use std::os::raw::c_void;

use upac_types::TmpPath;
use upac_types::hook::Message;
use upac_types::states::CommitStateId;
use upac_types::traits::MessageHook;

use upac_abi::HookMessageFn;
use upac_abi::error::ErrorKind;
use upac_abi::hook::CancelToken;
use upac_abi::request::CCommitRequest;

use self::transaction::TransactionStage;

use crate::deploy::retention::RetentionStage;
use crate::deploy::{Deploy, DeployMode};
use crate::orchestrator::context::Context;
use crate::orchestrator::{Orchestrator, SequentialOrchestrator, run_mutating};
use crate::scripts::HookStage;
use crate::scripts::pipeline::{Operation, PipelineTrigger};

pub use self::error::CommitError;

mod error;
mod transaction;

pub(crate) struct CommitInfo {
    pub subject: String,
    pub message: Option<String>,
}

pub struct CommitData<'a> {
    pub tmp_path: &'a str,

    pub subject: &'a str,
    pub message: Option<&'a str>,

    pub hook_message: Option<HookMessageFn>,
    pub hook_message_context: *mut c_void,

    pub cancel_token: &'a CancelToken,
}

impl<'a> TryFrom<&'a CCommitRequest> for CommitData<'a> {
    type Error = ErrorKind;

    fn try_from(request: &'a CCommitRequest) -> Result<Self, ErrorKind> {
        unsafe { request.validate()? };

        let cancel_token = unsafe { &*request.base.cancel_token };

        Ok(CommitData {
            tmp_path: (&request.tmp_path).try_into()?,

            subject: (&request.subject).try_into()?,
            message: (&request.message).try_into()?,

            hook_message: request.base.on_hook,
            hook_message_context: request.base.hook_ctx,

            cancel_token,
        })
    }
}

pub fn run(data: CommitData) -> Result<(), (CommitStateId, CommitError)> {
    let deploy =
        Deploy::new(DeployMode::ReadWrite).map_err(|error| (CommitStateId::Setup, CommitError::from(error)))?;

    let mut context = Context::new();
    context.put(deploy);
    context.put(TmpPath(data.tmp_path.to_owned()));
    context.put(CommitInfo {
        subject: data.subject.to_owned(),
        message: data.message.map(str::to_owned),
    });
    context.put(Box::new(Message::new(data.hook_message, data.hook_message_context)) as Box<dyn MessageHook>);

    let orchestrator = assemble();

    let result = run_mutating!(orchestrator, context, data.cancel_token, CommitStateId, CommitError);

    data.cancel_token.reset();

    result
}

fn assemble() -> SequentialOrchestrator<CommitError> {
    SequentialOrchestrator::new(vec![
        Box::new(HookStage {
            trigger: PipelineTrigger::pre(Operation::Commit),
        }),
        Box::new(TransactionStage),
        Box::new(HookStage {
            trigger: PipelineTrigger::post(Operation::Commit),
        }),
        Box::new(RetentionStage),
    ])
}
