// SPDX-FileCopyrightText: 2026 JustPav
// SPDX-FileCopyrightText: 2026 SmoothTeam
//
// SPDX-License-Identifier: GPL-3.0-only

use std::ptr::null_mut;

use anyhow::Result;

use chrono::{Local, TimeZone};

use clap::Args as ClapArgs;

use colored::Colorize;

use upac_abi::request::CListPrefixRequest;

use upac_types::request::{ListPrefixRequest, RequestBase};

use crate::cancel_token_ptr;
use crate::types::CommandContext;
use crate::types::abi::invoke_with_response;

#[derive(ClapArgs)]
pub struct Args {}

pub fn run(_args: Args, ctx: CommandContext) -> Result<()> {
    let request: CListPrefixRequest = ListPrefixRequest {
        base: RequestBase {
            on_hook: None,
            hook_ctx: null_mut(),
            cancel_token: cancel_token_ptr(),
        },
    }
    .into();

    let response = invoke_with_response(|out, error| unsafe { (ctx.lib.ro.list_prefix)(request, out, error) })?;

    let prefixes = unsafe { response.prefixes.as_slice() };
    for (index, prefix) in prefixes.iter().enumerate() {
        let digest = <&str>::try_from(&prefix.prefix_digest).unwrap_or_default();
        let subject = <&str>::try_from(&prefix.subject).unwrap_or_default();

        println!("{}", subject.bold());
        if let Some(timestamp) = Local.timestamp_opt(prefix.timestamp as i64, 0).single() {
            println!("{}", timestamp.format("%Y-%m-%d %H:%M:%S").to_string().dimmed());
        }
        println!("{}", digest.yellow());

        if index < prefixes.len() - 1 {
            println!();
        }
    }

    unsafe { response.free() };

    Ok(())
}
