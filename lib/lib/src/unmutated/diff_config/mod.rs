// SPDX-FileCopyrightText: 2026 JustPav
// SPDX-FileCopyrightText: 2026 SmoothTeam
//
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

use std::os::raw::c_void;

use upac_abi::FileDiffKind;
use upac_abi::HookMessageFn;
use upac_abi::error::ErrorKind;
use upac_abi::hook::CancelToken;
use upac_abi::request::CDiffConfigRequest;

use upac_types::RequestedConfigDigestRange;
use upac_types::entry::DiffConfigFileEntry;
use upac_types::hook::Message;
use upac_types::response::DiffConfigResponse;
use upac_types::states::DiffConfigStateId;
use upac_types::traits::MessageHook;

use self::comparing::ComparingStage;
use self::preparing::PreparingStage;

use crate::database::MemoryDatabase;
use crate::orchestrator::context::Context;
use crate::orchestrator::{Orchestrator, SequentialOrchestrator, run_unmutated};

pub use self::error::DiffConfigError;

mod comparing;
mod error;
mod preparing;

struct DiffConfigSnapshot {
    changed: Vec<(String, FileDiffKind)>,
    from_database: MemoryDatabase,
    to_database: MemoryDatabase,
}

pub struct DiffConfigData<'a> {
    pub from_config_digest: Option<&'a str>,
    pub to_config_digest: Option<&'a str>,

    pub hook_message: Option<HookMessageFn>,
    pub hook_message_context: *mut c_void,

    pub cancel_token: &'a CancelToken,
}

impl<'a> TryFrom<&'a CDiffConfigRequest> for DiffConfigData<'a> {
    type Error = ErrorKind;

    fn try_from(request: &'a CDiffConfigRequest) -> Result<Self, ErrorKind> {
        unsafe { request.validate()? };

        let cancel_token = unsafe { &*request.base.cancel_token };

        Ok(DiffConfigData {
            from_config_digest: (&request.from_config_digest).try_into()?,
            to_config_digest: (&request.to_config_digest).try_into()?,

            hook_message: request.base.on_hook,
            hook_message_context: request.base.hook_ctx,

            cancel_token,
        })
    }
}

pub fn run(data: DiffConfigData) -> Result<DiffConfigResponse, (DiffConfigStateId, DiffConfigError)> {
    let mut context = Context::new();
    context.put(RequestedConfigDigestRange {
        from: data.from_config_digest.map(str::to_owned),
        to: data.to_config_digest.map(str::to_owned),
    });
    context.put(Box::new(Message::new(data.hook_message, data.hook_message_context)) as Box<dyn MessageHook>);

    let orchestrator = SequentialOrchestrator::new(vec![Box::new(PreparingStage), Box::new(ComparingStage)]);

    let (files,) = run_unmutated!(
        orchestrator,
        context,
        data.cancel_token,
        DiffConfigStateId,
        DiffConfigError,
        Vec<DiffConfigFileEntry>
    )?;

    Ok(DiffConfigResponse { files })
}
