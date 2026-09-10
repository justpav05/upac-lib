// SPDX-FileCopyrightText: 2026 JustPav
// SPDX-FileCopyrightText: 2026 SmoothTeam
//
// SPDX-License-Identifier: GPL-3.0-only

use std::ptr::null_mut;

use anyhow::Result;

use clap::Args as ClapArgs;

use colored::Colorize;

use upac_abi::request::CListConfigRequest;

use upac_types::request::{ListConfigRequest, RequestBase};

use crate::cancel_token_ptr;
use crate::types::CommandContext;
use crate::types::abi::invoke_with_response;

#[derive(ClapArgs)]
pub struct Args {}

pub fn run(_args: Args, ctx: CommandContext) -> Result<()> {
    let request: CListConfigRequest = ListConfigRequest {
        base: RequestBase {
            on_hook: None,
            hook_ctx: null_mut(),
            cancel_token: cancel_token_ptr(),
        },
        prefix_digest: None,
    }
    .into();

    let response = invoke_with_response(|out, error| unsafe { (ctx.lib.ro.list_config)(request, out, error) })?;

    let commits = unsafe { response.commits.as_slice() };
    for (index, commit) in commits.iter().enumerate() {
        let digest = <&str>::try_from(&commit.config_digest).unwrap_or_default();
        let subject = <&str>::try_from(&commit.subject).unwrap_or_default();

        println!("{}", subject.bold());
        println!("{}", digest.yellow());

        if index < commits.len() - 1 {
            println!();
        }
    }

    unsafe { response.free() };

    Ok(())
}
