// SPDX-FileCopyrightText: 2026 JustPav
// SPDX-FileCopyrightText: 2026 SmoothTeam
//
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

use std::os::raw::c_void;

use upac_abi::HookMessageFn;
use upac_abi::error::ErrorKind;
use upac_abi::hook::CancelToken;
use upac_abi::request::CDiffRequest;
use upac_abi::{DiffFileSource, FileDiffKind};

use upac_types::entry::{DiffPackageEntry, DiffUntrackedFileEntry};
use upac_types::hook::Message;
use upac_types::package::PackageMeta;
use upac_types::response::DiffResponse;
use upac_types::states::DiffStateId;
use upac_types::traits::MessageHook;
use upac_types::{RequestedConfigDigestRange, RequestedPrefixDigestRange};

use self::comparing::ComparingStage;
use self::preparing::PreparingStage;

use crate::database::MemoryDatabase;
use crate::orchestrator::context::Context;
use crate::orchestrator::{Orchestrator, SequentialOrchestrator, run_unmutated};

pub use self::error::DiffError;

mod comparing;
mod error;
mod preparing;

struct DiffSnapshot {
    from_packages: Vec<PackageMeta>,
    to_packages: Vec<PackageMeta>,

    changed_files: Vec<(String, FileDiffKind, DiffFileSource)>,

    from_database: MemoryDatabase,
    to_database: MemoryDatabase,
}

pub struct DiffData<'a> {
    pub from_prefix_digest: Option<&'a str>,
    pub to_prefix_digest: Option<&'a str>,
    pub from_config_digest: Option<&'a str>,
    pub to_config_digest: Option<&'a str>,

    pub hook_message: Option<HookMessageFn>,
    pub hook_message_context: *mut c_void,

    pub cancel_token: &'a CancelToken,
}

impl<'a> TryFrom<&'a CDiffRequest> for DiffData<'a> {
    type Error = ErrorKind;

    fn try_from(request: &'a CDiffRequest) -> Result<Self, ErrorKind> {
        unsafe { request.validate()? };

        let cancel_token = unsafe { &*request.base.cancel_token };

        Ok(DiffData {
            from_prefix_digest: (&request.from_prefix_digest).try_into()?,
            to_prefix_digest: (&request.to_prefix_digest).try_into()?,
            from_config_digest: (&request.from_config_digest).try_into()?,
            to_config_digest: (&request.to_config_digest).try_into()?,

            hook_message: request.base.on_hook,
            hook_message_context: request.base.hook_ctx,

            cancel_token,
        })
    }
}

pub fn run(data: DiffData) -> Result<DiffResponse, (DiffStateId, DiffError)> {
    let mut context = Context::new();
    context.put(RequestedPrefixDigestRange {
        from: data.from_prefix_digest.map(str::to_owned),
        to: data.to_prefix_digest.map(str::to_owned),
    });

    context.put(RequestedConfigDigestRange {
        from: data.from_config_digest.map(str::to_owned),
        to: data.to_config_digest.map(str::to_owned),
    });

    context.put(Box::new(Message::new(data.hook_message, data.hook_message_context)) as Box<dyn MessageHook>);

    let orchestrator = SequentialOrchestrator::new(vec![Box::new(PreparingStage), Box::new(ComparingStage)]);

    let (diff_packages, unattached_files) = run_unmutated!(
        orchestrator,
        context,
        data.cancel_token,
        DiffStateId,
        DiffError,
        Vec<DiffPackageEntry>,
        Vec<DiffUntrackedFileEntry>
    )?;

    Ok(DiffResponse {
        diff_packages,
        unattached_files,
    })
}
