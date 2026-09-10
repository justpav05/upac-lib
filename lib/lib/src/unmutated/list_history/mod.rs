// SPDX-FileCopyrightText: 2026 JustPav
// SPDX-FileCopyrightText: 2026 SmoothTeam
//
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

use std::os::raw::c_void;

use upac_abi::HookMessageFn;
use upac_abi::error::ErrorKind;
use upac_abi::hook::CancelToken;
use upac_abi::request::CListHistoryRequest;

use upac_types::entry::HistoryEntry;
use upac_types::hook::Message;
use upac_types::response::ListHistoryResponse;
use upac_types::states::ListHistoryStateId;
use upac_types::traits::MessageHook;

use self::fetching::FetchingStage;

use crate::orchestrator::context::Context;
use crate::orchestrator::{Orchestrator, SequentialOrchestrator, run_unmutated};

pub use self::error::ListHistoryError;

mod error;
mod fetching;

pub struct ListHistoryData<'a> {
    pub hook_message: Option<HookMessageFn>,
    pub hook_message_context: *mut c_void,

    pub cancel_token: &'a CancelToken,
}

impl<'a> TryFrom<&'a CListHistoryRequest> for ListHistoryData<'a> {
    type Error = ErrorKind;

    fn try_from(request: &'a CListHistoryRequest) -> Result<Self, ErrorKind> {
        unsafe { request.validate()? };

        let cancel_token = unsafe { &*request.base.cancel_token };

        Ok(ListHistoryData {
            hook_message: request.base.on_hook,
            hook_message_context: request.base.hook_ctx,

            cancel_token,
        })
    }
}

pub fn run(data: ListHistoryData) -> Result<ListHistoryResponse, (ListHistoryStateId, ListHistoryError)> {
    let mut context = Context::new();
    context.put(Box::new(Message::new(data.hook_message, data.hook_message_context)) as Box<dyn MessageHook>);

    let orchestrator = SequentialOrchestrator::new(vec![Box::new(FetchingStage)]);

    let (history,) = run_unmutated!(
        orchestrator,
        context,
        data.cancel_token,
        ListHistoryStateId,
        ListHistoryError,
        Vec<HistoryEntry>
    )?;

    Ok(ListHistoryResponse { history })
}
