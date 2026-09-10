// SPDX-FileCopyrightText: 2026 JustPav
// SPDX-FileCopyrightText: 2026 SmoothTeam
//
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

use std::os::raw::c_void;

use upac_abi::HookMessageFn;
use upac_abi::error::ErrorKind;
use upac_abi::hook::CancelToken;
use upac_abi::request::CListConfigRequest;

use upac_types::RequestedPrefixDigest;
use upac_types::entry::ConfigCommitEntry;
use upac_types::hook::Message;
use upac_types::response::ListConfigResponse;
use upac_types::states::ListConfigStateId;
use upac_types::traits::MessageHook;

use self::fetching::FetchingStage;

use crate::orchestrator::context::Context;
use crate::orchestrator::{Orchestrator, SequentialOrchestrator, run_unmutated};

pub use self::error::ListConfigError;

mod error;
mod fetching;

pub struct ListConfigData<'a> {
    pub prefix_digest: Option<&'a str>,

    pub hook_message: Option<HookMessageFn>,
    pub hook_message_context: *mut c_void,

    pub cancel_token: &'a CancelToken,
}

impl<'a> TryFrom<&'a CListConfigRequest> for ListConfigData<'a> {
    type Error = ErrorKind;

    fn try_from(request: &'a CListConfigRequest) -> Result<Self, ErrorKind> {
        unsafe { request.validate()? };

        let cancel_token = unsafe { &*request.base.cancel_token };

        Ok(ListConfigData {
            prefix_digest: (&request.prefix_digest).try_into()?,

            hook_message: request.base.on_hook,
            hook_message_context: request.base.hook_ctx,

            cancel_token,
        })
    }
}

pub fn run(data: ListConfigData) -> Result<ListConfigResponse, (ListConfigStateId, ListConfigError)> {
    let mut context = Context::new();
    context.put(RequestedPrefixDigest(data.prefix_digest.map(str::to_owned)));
    context.put(Box::new(Message::new(data.hook_message, data.hook_message_context)) as Box<dyn MessageHook>);

    let orchestrator = SequentialOrchestrator::new(vec![Box::new(FetchingStage)]);

    let (commits,) = run_unmutated!(
        orchestrator,
        context,
        data.cancel_token,
        ListConfigStateId,
        ListConfigError,
        Vec<ConfigCommitEntry>
    )?;

    Ok(ListConfigResponse { commits })
}
