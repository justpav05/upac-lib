// SPDX-FileCopyrightText: 2026 JustPav
// SPDX-FileCopyrightText: 2026 SmoothTeam
//
// SPDX-License-Identifier: GPL-3.0-only

use std::ptr::null_mut;

use anyhow::Result;

use chrono::{Local, TimeZone};

use clap::Args as ClapArgs;

use colored::Colorize;

use upac_abi::request::CListHistoryRequest;

use upac_types::request::{ListHistoryRequest, RequestBase};

use crate::cancel_token_ptr;
use crate::types::CommandContext;
use crate::types::abi::invoke_with_response;

#[derive(ClapArgs)]
pub struct Args {}

pub fn run(_args: Args, ctx: CommandContext) -> Result<()> {
    let request: CListHistoryRequest = ListHistoryRequest {
        base: RequestBase {
            on_hook: None,
            hook_ctx: null_mut(),
            cancel_token: cancel_token_ptr(),
        },
    }
    .into();

    let response = invoke_with_response(|out, error| unsafe { (ctx.lib.ro.list_history)(request, out, error) })?;

    let entries = unsafe { response.history.as_slice() };
    for (index, entry) in entries.iter().enumerate() {
        let digest = <&str>::try_from(&entry.prefix_digest).unwrap_or_default();
        let subject = <&str>::try_from(&entry.subject).unwrap_or_default();
        let working_config = Option::<&str>::try_from(&entry.working_config).unwrap_or_default();

        println!("{}", subject.bold());
        if let Some(timestamp) = Local.timestamp_opt(entry.timestamp as i64, 0).single() {
            println!("{}", timestamp.format("%Y-%m-%d %H:%M:%S").to_string().dimmed());
        }
        println!("{}", digest.yellow());

        for config in unsafe { entry.config_history.as_slice() } {
            let config_digest = <&str>::try_from(&config.config_digest).unwrap_or_default();
            let config_subject = <&str>::try_from(&config.subject).unwrap_or_default();
            let marker = if working_config == Some(config_digest) {
                "*"
            } else {
                " "
            };

            println!("  {marker} {config_subject} {}", config_digest.yellow());
        }

        if index < entries.len() - 1 {
            println!();
        }
    }

    unsafe { response.free() };

    Ok(())
}
