// SPDX-FileCopyrightText: 2026 JustPav
// SPDX-FileCopyrightText: 2026 SmoothTeam
//
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

use std::os::raw::c_void;

use upac_abi::HookMessageFn;
use upac_abi::error::ErrorKind;
use upac_abi::hook::CancelToken;
use upac_abi::request::CSearchFilesRequest;

use upac_types::entry::SearchFileEntry;
use upac_types::hook::Message;
use upac_types::response::SearchFilesResponse;
use upac_types::states::SearchFilesStateId;
use upac_types::traits::MessageHook;

use self::searching::SearchingStage;

use crate::orchestrator::context::Context;
use crate::orchestrator::{Orchestrator, SequentialOrchestrator, run_unmutated};
use crate::search::Search;

pub use self::error::SearchFilesError;

mod error;
mod searching;

pub struct SearchFilesData<'a> {
    pub search: &'a str,
    pub is_regex: bool,

    pub hook_message: Option<HookMessageFn>,
    pub hook_message_context: *mut c_void,

    pub cancel_token: &'a CancelToken,
}

impl<'a> TryFrom<&'a CSearchFilesRequest> for SearchFilesData<'a> {
    type Error = ErrorKind;

    fn try_from(request: &'a CSearchFilesRequest) -> Result<Self, ErrorKind> {
        unsafe { request.validate()? };

        let cancel_token = unsafe { &*request.base.cancel_token };

        Ok(SearchFilesData {
            search: (&request.search).try_into()?,
            is_regex: request.is_regex,

            hook_message: request.base.on_hook,
            hook_message_context: request.base.hook_ctx,

            cancel_token,
        })
    }
}

pub fn run(data: SearchFilesData) -> Result<SearchFilesResponse, (SearchFilesStateId, SearchFilesError)> {
    let search = Search::new(data.search, data.is_regex)
        .map_err(|error| (SearchFilesStateId::Setup, SearchFilesError::from(error)))?;

    let mut context = Context::new();
    context.put(search);
    context.put(Box::new(Message::new(data.hook_message, data.hook_message_context)) as Box<dyn MessageHook>);

    let orchestrator = SequentialOrchestrator::new(vec![Box::new(SearchingStage)]);

    let (files,) = run_unmutated!(
        orchestrator,
        context,
        data.cancel_token,
        SearchFilesStateId,
        SearchFilesError,
        Vec<SearchFileEntry>
    )?;

    Ok(SearchFilesResponse { files })
}
