// SPDX-FileCopyrightText: 2026 JustPav
// SPDX-FileCopyrightText: 2026 SmoothTeam
//
// SPDX-License-Identifier: GPL-3.0-only

use std::ptr::null_mut;

use anyhow::Result;

use clap::Args as ClapArgs;

use upac_abi::request::CCommitRequest;

use upac_types::request::{CommitRequest, RequestBase};

use crate::cancel_token_ptr;
use crate::types::CommandContext;
use crate::types::abi::invoke;

#[derive(ClapArgs)]
pub struct Args {
    pub message: String,
}

pub fn run(args: Args, ctx: CommandContext) -> Result<()> {
    let symbols = ctx.lib.require_write()?;

    let request: CCommitRequest = CommitRequest {
        base: RequestBase {
            on_hook: None,
            hook_ctx: null_mut(),
            cancel_token: cancel_token_ptr(),
        },
        tmp_path: ctx.tmp_path.to_string_lossy().into_owned(),
        subject: args.message,
        message: None,
    }
    .into();

    invoke(|error| unsafe { (symbols.commit)(request, error) })
}
