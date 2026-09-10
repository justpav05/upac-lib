// SPDX-FileCopyrightText: 2026 JustPav
// SPDX-FileCopyrightText: 2026 SmoothTeam
//
// SPDX-License-Identifier: GPL-3.0-only

use std::ptr::null_mut;

use anyhow::Result;

use clap::Args as ClapArgs;

use upac_abi::request::CPinRequest;

use upac_types::request::{PinRequest, RequestBase};

use crate::cancel_token_ptr;
use crate::types::CommandContext;
use crate::types::abi::invoke;

#[derive(ClapArgs)]
pub struct Args {
    pub digest: String,
}

pub fn run(args: Args, ctx: CommandContext) -> Result<()> {
    let symbols = ctx.lib.require_write()?;

    let request: CPinRequest = PinRequest {
        base: RequestBase {
            on_hook: None,
            hook_ctx: null_mut(),
            cancel_token: cancel_token_ptr(),
        },
        prefix_digest: args.digest,
        pinned: false,
    }
    .into();

    invoke(|error| unsafe { (symbols.pin_deploy)(request, error) })
}
