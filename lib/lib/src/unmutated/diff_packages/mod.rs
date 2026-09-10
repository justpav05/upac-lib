// SPDX-FileCopyrightText: 2026 JustPav
// SPDX-FileCopyrightText: 2026 SmoothTeam
//
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

use std::os::raw::c_void;

use upac_abi::HookMessageFn;
use upac_abi::error::ErrorKind;
use upac_abi::hook::CancelToken;
use upac_abi::request::CDiffPackagesRequest;

use upac_types::RequestedPrefixDigestRange;
use upac_types::entry::DiffPackageEntry;
use upac_types::hook::Message;
use upac_types::response::DiffPackagesResponse;
use upac_types::states::DiffPackagesStateId;
use upac_types::traits::MessageHook;

use self::comparing::ComparingStage;
use self::preparing::PreparingStage;

use crate::orchestrator::context::Context;
use crate::orchestrator::{Orchestrator, SequentialOrchestrator, run_unmutated};

pub use self::error::DiffPackagesError;

mod comparing;
mod error;
mod preparing;

pub struct DiffPackagesData<'a> {
    pub from_prefix_digest: Option<&'a str>,
    pub to_prefix_digest: Option<&'a str>,

    pub hook_message: Option<HookMessageFn>,
    pub hook_message_context: *mut c_void,

    pub cancel_token: &'a CancelToken,
}

impl<'a> TryFrom<&'a CDiffPackagesRequest> for DiffPackagesData<'a> {
    type Error = ErrorKind;

    fn try_from(request: &'a CDiffPackagesRequest) -> Result<Self, ErrorKind> {
        unsafe { request.validate()? };

        let cancel_token = unsafe { &*request.base.cancel_token };

        Ok(DiffPackagesData {
            from_prefix_digest: (&request.from_prefix_digest).try_into()?,
            to_prefix_digest: (&request.to_prefix_digest).try_into()?,

            hook_message: request.base.on_hook,
            hook_message_context: request.base.hook_ctx,

            cancel_token,
        })
    }
}

pub fn run(data: DiffPackagesData) -> Result<DiffPackagesResponse, (DiffPackagesStateId, DiffPackagesError)> {
    let mut context = Context::new();
    context.put(RequestedPrefixDigestRange {
        from: data.from_prefix_digest.map(str::to_owned),
        to: data.to_prefix_digest.map(str::to_owned),
    });
    context.put(Box::new(Message::new(data.hook_message, data.hook_message_context)) as Box<dyn MessageHook>);

    let orchestrator = SequentialOrchestrator::new(vec![Box::new(PreparingStage), Box::new(ComparingStage)]);

    let (diff_packages,) = run_unmutated!(
        orchestrator,
        context,
        data.cancel_token,
        DiffPackagesStateId,
        DiffPackagesError,
        Vec<DiffPackageEntry>
    )?;

    Ok(DiffPackagesResponse { diff_packages })
}
