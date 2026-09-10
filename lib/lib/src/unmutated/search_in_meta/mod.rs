// SPDX-FileCopyrightText: 2026 JustPav
// SPDX-FileCopyrightText: 2026 SmoothTeam
//
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

use std::os::raw::c_void;

use upac_abi::HookMessageFn;
use upac_abi::error::ErrorKind;
use upac_abi::hook::CancelToken;
use upac_abi::request::CSearchInMetaRequest;

use upac_types::hook::Message;
use upac_types::package::{PackageEntry, PackageMeta};
use upac_types::response::SearchInMetaResponse;
use upac_types::states::SearchInMetaStateId;
use upac_types::traits::MessageHook;

use self::searching::SearchingStage;

use crate::orchestrator::context::Context;
use crate::orchestrator::{Orchestrator, SequentialOrchestrator, run_unmutated};
use crate::search::Search;

pub use self::error::SearchInMetaError;

mod error;
mod searching;

pub struct SearchInMetaData<'a> {
    pub name: &'a str,
    pub arch: &'a str,
    pub arch_sub: Option<&'a str>,
    pub search: &'a str,
    pub is_regex: bool,

    pub hook_message: Option<HookMessageFn>,
    pub hook_message_context: *mut c_void,

    pub cancel_token: &'a CancelToken,
}

impl<'a> TryFrom<&'a CSearchInMetaRequest> for SearchInMetaData<'a> {
    type Error = ErrorKind;

    fn try_from(request: &'a CSearchInMetaRequest) -> Result<Self, ErrorKind> {
        unsafe { request.validate()? };

        let cancel_token = unsafe { &*request.base.cancel_token };

        Ok(SearchInMetaData {
            name: (&request.package.name).try_into()?,
            arch: (&request.package.arch).try_into()?,
            arch_sub: (&request.package.arch_sub).try_into()?,
            search: (&request.search).try_into()?,
            is_regex: request.is_regex,

            hook_message: request.base.on_hook,
            hook_message_context: request.base.hook_ctx,

            cancel_token,
        })
    }
}

pub fn run(data: SearchInMetaData) -> Result<SearchInMetaResponse, (SearchInMetaStateId, SearchInMetaError)> {
    let search = Search::new(data.search, data.is_regex)
        .map_err(|error| (SearchInMetaStateId::Setup, SearchInMetaError::from(error)))?;

    let mut context = Context::new();
    context.put(PackageEntry {
        name: data.name.to_owned(),
        arch: data.arch.to_owned(),
        arch_sub: data.arch_sub.map(str::to_owned),
    });
    context.put(search);
    context.put(Box::new(Message::new(data.hook_message, data.hook_message_context)) as Box<dyn MessageHook>);

    let orchestrator = SequentialOrchestrator::new(vec![Box::new(SearchingStage)]);

    let (metas,) = run_unmutated!(
        orchestrator,
        context,
        data.cancel_token,
        SearchInMetaStateId,
        SearchInMetaError,
        Vec<PackageMeta>
    )?;

    Ok(SearchInMetaResponse { metas })
}
