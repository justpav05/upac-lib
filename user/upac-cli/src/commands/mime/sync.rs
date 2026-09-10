// SPDX-FileCopyrightText: 2026 JustPav
// SPDX-FileCopyrightText: 2026 SmoothTeam
//
// SPDX-License-Identifier: GPL-3.0-only

use std::ptr::null_mut;

use anyhow::Result;

use clap::Args as ClapArgs;

use upac_abi::request::CMimeSyncRequest;

use upac_types::request::{MimeSyncRequest, RequestBase};

use crate::cancel_token_ptr;
use crate::types::CommandContext;
use crate::types::abi::invoke;

#[derive(ClapArgs)]
pub struct Args {}

pub fn run(_args: Args, ctx: CommandContext) -> Result<()> {
    let symbols = ctx.lib.require_write()?;

    let request: CMimeSyncRequest = MimeSyncRequest {
        base: RequestBase {
            on_hook: None,
            hook_ctx: null_mut(),
            cancel_token: cancel_token_ptr(),
        },
    }
    .into();

    invoke(|error| unsafe { (symbols.mime)(request, error) })
}
