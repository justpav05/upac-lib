// SPDX-FileCopyrightText: 2026 JustPav
// SPDX-FileCopyrightText: 2026 SmoothTeam
//
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

use std::os::raw::c_void;

use upac_abi::HookMessageFn;
use upac_abi::error::ErrorKind;
use upac_abi::hook::CancelToken;
use upac_abi::request::CRollbackRequest;

use upac_types::TmpPath;
use upac_types::hook::Message;
use upac_types::states::RollbackStateId;
use upac_types::traits::MessageHook;

use upac_macro::ContextValue;

use self::checkout::CheckoutStage;
use self::merge::MergeStage;
use self::swap::SwapStage;

use crate::deploy::retention::RetentionStage;
use crate::deploy::{Deploy, DeployMode};
use crate::orchestrator::context::Context;
use crate::orchestrator::{Orchestrator, SequentialOrchestrator, run_mutating};
use crate::plugin::boot::BootPlugin;
use crate::scripts::HookStage;
use crate::scripts::pipeline::{Operation, PipelineTrigger};

pub use self::error::RollbackError;

mod checkout;
mod error;
mod merge;
mod swap;

#[derive(ContextValue)]
pub(crate) struct RequestedConfigDigest(pub String);

#[derive(ContextValue)]
pub(crate) struct TargetPrefixDigest(pub String);

#[derive(ContextValue)]
pub(crate) struct RequestedBootPlugin(pub String);

pub(crate) struct ResolvedBootEntry {
    pub plugin: BootPlugin,
    pub entry_name: String,
}

pub struct RollbackData<'a> {
    pub config_digest: &'a str,

    pub boot_plugin: &'a str,

    pub tmp_path: &'a str,

    pub hook_message: Option<HookMessageFn>,
    pub hook_message_context: *mut c_void,

    pub cancel_token: &'a CancelToken,
}

impl<'a> TryFrom<&'a CRollbackRequest> for RollbackData<'a> {
    type Error = ErrorKind;

    fn try_from(request: &'a CRollbackRequest) -> Result<Self, ErrorKind> {
        unsafe { request.validate()? };

        let cancel_token = unsafe { &*request.base.cancel_token };

        Ok(RollbackData {
            config_digest: (&request.config_digest).try_into()?,

            boot_plugin: (&request.boot_plugin).try_into()?,

            tmp_path: (&request.tmp_path).try_into()?,

            hook_message: request.base.on_hook,
            hook_message_context: request.base.hook_ctx,

            cancel_token,
        })
    }
}

pub fn run(data: RollbackData) -> Result<(), (RollbackStateId, RollbackError)> {
    let deploy =
        Deploy::new(DeployMode::ReadOnly).map_err(|error| (RollbackStateId::Setup, RollbackError::from(error)))?;

    let mut context = Context::new();
    context.put(deploy);
    context.put(RequestedConfigDigest(data.config_digest.to_owned()));
    context.put(RequestedBootPlugin(data.boot_plugin.to_owned()));
    context.put(TmpPath(data.tmp_path.to_owned()));
    context.put(Box::new(Message::new(data.hook_message, data.hook_message_context)) as Box<dyn MessageHook>);

    let orchestrator = assemble();

    let result = run_mutating!(orchestrator, context, data.cancel_token, RollbackStateId, RollbackError);

    data.cancel_token.reset();

    result
}

fn assemble() -> SequentialOrchestrator<RollbackError> {
    SequentialOrchestrator::new(vec![
        Box::new(HookStage {
            trigger: PipelineTrigger::pre(Operation::Rollback),
        }),
        Box::new(MergeStage),
        Box::new(CheckoutStage),
        Box::new(SwapStage),
        Box::new(HookStage {
            trigger: PipelineTrigger::post(Operation::Rollback),
        }),
        Box::new(RetentionStage),
    ])
}
