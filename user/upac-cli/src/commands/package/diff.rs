// SPDX-FileCopyrightText: 2026 JustPav
// SPDX-FileCopyrightText: 2026 SmoothTeam
//
// SPDX-License-Identifier: GPL-3.0-only

use std::ptr::null_mut;

use anyhow::Result;

use clap::Args as ClapArgs;

use colored::Colorize;

use upac_abi::PackageDiffKind;
use upac_abi::request::CDiffPackagesRequest;

use upac_types::request::{DiffPackagesRequest, RequestBase};

use crate::cancel_token_ptr;
use crate::commands::display::VersionDisplay;
use crate::types::CommandContext;
use crate::types::abi::invoke_with_response;

#[derive(ClapArgs)]
pub struct Args {
    pub from: Option<String>,
    pub to: Option<String>,
}

pub fn run(args: Args, ctx: CommandContext) -> Result<()> {
    let request: CDiffPackagesRequest = DiffPackagesRequest {
        base: RequestBase {
            on_hook: None,
            hook_ctx: null_mut(),
            cancel_token: cancel_token_ptr(),
        },
        from_prefix_digest: args.from,
        to_prefix_digest: args.to,
    }
    .into();

    let response = invoke_with_response(|out, error| unsafe { (ctx.lib.ro.diff_packages)(request, out, error) })?;

    for entry in unsafe { response.diff_packages.as_slice() } {
        let name = <&str>::try_from(&entry.name).unwrap_or_default();
        let version = VersionDisplay(&entry.version);

        let (marker, colored_name) = match entry.kind {
            PackageDiffKind::Added => ("+".green().bold(), name.green()),
            PackageDiffKind::Removed => ("-".red().bold(), name.red()),
            PackageDiffKind::Modified => ("~".yellow().bold(), name.yellow()),
            PackageDiffKind::FilesChanged => ("*".yellow().bold(), name.yellow()),
        };
        println!("{} {} {}", marker, colored_name.bold(), version);
    }

    unsafe { response.free() };

    Ok(())
}
