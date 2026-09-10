// SPDX-FileCopyrightText: 2026 JustPav
// SPDX-FileCopyrightText: 2026 SmoothTeam
//
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

use std::collections::VecDeque;
use std::os::raw::c_void;

use upac_abi::HookMessageFn;
use upac_abi::error::ErrorKind;
use upac_abi::hook::CancelToken;
use upac_abi::request::CGcRequest;

use upac_types::hook::Message;
use upac_types::traits::MessageHook;

use upac_types::states::GcStateId;

use upac_macro::ContextValue;

use self::cleaning::CleaningStage;
use self::collect::CollectRootsStage;
use self::pruning::PruneStage;

use crate::deploy::{Deploy, DeployMode};
use crate::orchestrator::context::Context;
use crate::orchestrator::{Orchestrator, SequentialOrchestrator, run_mutating};

pub use self::error::GcError;

mod cleaning;
mod collect;
mod error;
mod pruning;

pub(crate) struct DeployProgress {
    pub pending: VecDeque<String>,
    pub total: u64,
}

#[derive(ContextValue)]
pub(crate) struct CollectedRoots(pub Vec<String>);

pub struct GcData<'a> {
    pub hook_message: Option<HookMessageFn>,
    pub hook_message_context: *mut c_void,

    pub cancel_token: &'a CancelToken,
}

impl<'a> TryFrom<&'a CGcRequest> for GcData<'a> {
    type Error = ErrorKind;

    fn try_from(request: &'a CGcRequest) -> Result<Self, ErrorKind> {
        unsafe { request.validate()? };

        let cancel_token = unsafe { &*request.base.cancel_token };

        Ok(GcData {
            hook_message: request.base.on_hook,
            hook_message_context: request.base.hook_ctx,

            cancel_token,
        })
    }
}

pub fn run(data: GcData) -> Result<(), (GcStateId, GcError)> {
    let deploy = Deploy::new(DeployMode::ReadWrite).map_err(|error| (GcStateId::Setup, GcError::from(error)))?;

    let mut context = Context::new();
    context.put(deploy);
    context.put(Box::new(Message::new(data.hook_message, data.hook_message_context)) as Box<dyn MessageHook>);

    let orchestrator = SequentialOrchestrator::new(vec![
        Box::new(PruneStage),
        Box::new(CollectRootsStage),
        Box::new(CleaningStage),
    ]);

    let result = run_mutating!(orchestrator, context, data.cancel_token, GcStateId, GcError);

    data.cancel_token.reset();

    result
}
