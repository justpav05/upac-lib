// SPDX-FileCopyrightText: 2026 JustPav
// SPDX-FileCopyrightText: 2026 SmoothTeam
//
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

use std::os::raw::c_void;

use upac_abi::HookMessageFn;
use upac_abi::error::ErrorKind;
use upac_abi::hook::CancelToken;
use upac_abi::request::CPinRequest;
use upac_types::hook::Message;
use upac_types::traits::MessageHook;

use upac_types::states::PinStateId;

use upac_macro::ContextValue;

use self::stage::SetPinnedStage;

use crate::deploy::{Deploy, DeployMode};
use crate::orchestrator::context::Context;
use crate::orchestrator::{Orchestrator, SequentialOrchestrator, run_mutating};

pub use self::error::PinError;

mod error;
mod stage;

#[derive(ContextValue)]
pub(crate) struct RequestedPrefixDigest(pub String);

#[derive(ContextValue)]
pub(crate) struct RequestedPinned(pub bool);

pub struct PinData<'a> {
    pub prefix_digest: &'a str,
    pub pinned: bool,

    pub hook_message: Option<HookMessageFn>,
    pub hook_message_context: *mut c_void,

    pub cancel_token: &'a CancelToken,
}

impl<'a> TryFrom<&'a CPinRequest> for PinData<'a> {
    type Error = ErrorKind;

    fn try_from(request: &'a CPinRequest) -> Result<Self, ErrorKind> {
        unsafe { request.validate()? };

        let cancel_token = unsafe { &*request.base.cancel_token };

        Ok(PinData {
            prefix_digest: (&request.prefix_digest).try_into()?,
            pinned: request.pinned,

            hook_message: request.base.on_hook,
            hook_message_context: request.base.hook_ctx,

            cancel_token,
        })
    }
}

pub fn run(data: PinData) -> Result<(), (PinStateId, PinError)> {
    let deploy = Deploy::new(DeployMode::ReadWrite).map_err(|error| (PinStateId::Setup, PinError::from(error)))?;

    let mut context = Context::new();
    context.put(deploy);
    context.put(RequestedPrefixDigest(data.prefix_digest.to_owned()));
    context.put(RequestedPinned(data.pinned));
    context.put(Box::new(Message::new(data.hook_message, data.hook_message_context)) as Box<dyn MessageHook>);

    let orchestrator = SequentialOrchestrator::new(vec![Box::new(SetPinnedStage)]);

    let result = run_mutating!(orchestrator, context, data.cancel_token, PinStateId, PinError);

    data.cancel_token.reset();

    result
}
