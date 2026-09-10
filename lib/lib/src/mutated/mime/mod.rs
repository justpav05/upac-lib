// SPDX-FileCopyrightText: 2026 JustPav
// SPDX-FileCopyrightText: 2026 SmoothTeam
//
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

use std::collections::VecDeque;
use std::os::raw::c_void;

use upac_abi::HookMessageFn;
use upac_abi::error::ErrorKind;
use upac_abi::hook::CancelToken;
use upac_abi::request::CMimeSyncRequest;

use upac_types::hook::Message;
use upac_types::states::MimeStateId;
use upac_types::traits::MessageHook;

use upac_macro::ContextValue;

use self::preparing::PreparingStage;
use self::rendering::RenderingStage;
use self::writing::WritingStage;

use crate::orchestrator::context::Context;
use crate::orchestrator::{Orchestrator, SequentialOrchestrator, run_mutating};

pub use self::error::MimeError;

mod error;
mod preparing;
mod rendering;
mod writing;

#[derive(ContextValue)]
pub(crate) struct DesktopContent(pub String);

pub(crate) struct WriteProgress {
    pub pending: VecDeque<(&'static str, String)>,
    pub total: u64,
}

pub struct MimeData<'a> {
    pub hook_message: Option<HookMessageFn>,
    pub hook_message_context: *mut c_void,

    pub cancel_token: &'a CancelToken,
}

impl<'a> TryFrom<&'a CMimeSyncRequest> for MimeData<'a> {
    type Error = ErrorKind;

    fn try_from(request: &'a CMimeSyncRequest) -> Result<Self, ErrorKind> {
        unsafe { request.validate()? };

        let cancel_token = unsafe { &*request.base.cancel_token };

        Ok(MimeData {
            hook_message: request.base.on_hook,
            hook_message_context: request.base.hook_ctx,

            cancel_token,
        })
    }
}

pub fn run(data: MimeData) -> Result<(), (MimeStateId, MimeError)> {
    let mut context = Context::new();
    context.put(Box::new(Message::new(data.hook_message, data.hook_message_context)) as Box<dyn MessageHook>);

    let orchestrator = SequentialOrchestrator::new(vec![
        Box::new(PreparingStage),
        Box::new(RenderingStage),
        Box::new(WritingStage),
    ]);

    let result = run_mutating!(orchestrator, context, data.cancel_token, MimeStateId, MimeError);

    data.cancel_token.reset();

    result
}
