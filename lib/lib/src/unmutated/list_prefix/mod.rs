// SPDX-FileCopyrightText: 2026 JustPav
// SPDX-FileCopyrightText: 2026 SmoothTeam
//
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

use std::os::raw::c_void;

use upac_abi::HookMessageFn;
use upac_abi::error::ErrorKind;
use upac_abi::hook::CancelToken;
use upac_abi::request::CListPrefixRequest;

use upac_types::entry::PrefixEntry;
use upac_types::hook::Message;
use upac_types::response::ListPrefixResponse;
use upac_types::states::ListPrefixStateId;
use upac_types::traits::MessageHook;

use self::fetching::FetchingStage;

use crate::orchestrator::context::Context;
use crate::orchestrator::{Orchestrator, SequentialOrchestrator, run_unmutated};

pub use self::error::ListPrefixError;

mod error;
mod fetching;

pub struct ListPrefixData<'a> {
    pub hook_message: Option<HookMessageFn>,
    pub hook_message_context: *mut c_void,

    pub cancel_token: &'a CancelToken,
}

impl<'a> TryFrom<&'a CListPrefixRequest> for ListPrefixData<'a> {
    type Error = ErrorKind;

    fn try_from(request: &'a CListPrefixRequest) -> Result<Self, ErrorKind> {
        unsafe { request.validate()? };

        let cancel_token = unsafe { &*request.base.cancel_token };

        Ok(ListPrefixData {
            hook_message: request.base.on_hook,
            hook_message_context: request.base.hook_ctx,

            cancel_token,
        })
    }
}

pub fn run(data: ListPrefixData) -> Result<ListPrefixResponse, (ListPrefixStateId, ListPrefixError)> {
    let mut context = Context::new();
    context.put(Box::new(Message::new(data.hook_message, data.hook_message_context)) as Box<dyn MessageHook>);

    let orchestrator = SequentialOrchestrator::new(vec![Box::new(FetchingStage)]);

    let (prefixes,) = run_unmutated!(
        orchestrator,
        context,
        data.cancel_token,
        ListPrefixStateId,
        ListPrefixError,
        Vec<PrefixEntry>
    )?;

    Ok(ListPrefixResponse { prefixes })
}
