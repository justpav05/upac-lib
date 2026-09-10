// SPDX-FileCopyrightText: 2026 JustPav
// SPDX-FileCopyrightText: 2026 SmoothTeam
//
// SPDX-License-Identifier: GPL-3.0-only

use std::ptr::null_mut;

use anyhow::Result;

use clap::Args as ClapArgs;

use colored::Colorize;

use upac_abi::FileDiffKind;
use upac_abi::request::CDiffConfigRequest;

use upac_types::request::{DiffConfigRequest, RequestBase};

use crate::cancel_token_ptr;
use crate::types::CommandContext;
use crate::types::abi::invoke_with_response;

#[derive(ClapArgs)]
pub struct Args {
    pub from: Option<String>,
    pub to: Option<String>,
}

pub fn run(args: Args, ctx: CommandContext) -> Result<()> {
    let request: CDiffConfigRequest = DiffConfigRequest {
        base: RequestBase {
            on_hook: None,
            hook_ctx: null_mut(),
            cancel_token: cancel_token_ptr(),
        },
        from_config_digest: args.from,
        to_config_digest: args.to,
    }
    .into();

    let response = invoke_with_response(|out, error| unsafe { (ctx.lib.ro.diff_config)(request, out, error) })?;

    for entry in unsafe { response.files.as_slice() } {
        let path = <&str>::try_from(&entry.common.path).unwrap_or_default();
        let package_name = Option::<&str>::try_from(&entry.package_name).unwrap_or_default();

        let (marker, colored_path) = match entry.common.kind {
            FileDiffKind::Added => ("+".green().bold(), path.green()),
            FileDiffKind::Removed => ("-".red().bold(), path.red()),
            FileDiffKind::Modified => ("~".yellow().bold(), path.yellow()),
        };

        match package_name {
            Some(package_name) => println!("{} {} ({package_name})", marker, colored_path.bold()),
            None => println!("{} {}", marker, colored_path.bold()),
        }
    }

    unsafe { response.free() };

    Ok(())
}
