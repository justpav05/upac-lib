// SPDX-FileCopyrightText: 2026 JustPav
// SPDX-FileCopyrightText: 2026 SmoothTeam
//
// SPDX-License-Identifier: GPL-3.0-only

use std::ptr::null_mut;

use anyhow::Result;

use clap::Args as ClapArgs;

use colored::Colorize;

use upac_abi::request::CDiffRequest;
use upac_abi::{DiffFileSource, FileDiffKind, PackageDiffKind};

use upac_types::request::{DiffRequest, RequestBase};

use crate::cancel_token_ptr;
use crate::commands::display::VersionDisplay;
use crate::types::CommandContext;
use crate::types::abi::invoke_with_response;

#[derive(ClapArgs)]
pub struct Args {
    #[arg(long)]
    pub from_prefix: Option<String>,
    #[arg(long)]
    pub to_prefix: Option<String>,
    #[arg(long)]
    pub from_config: Option<String>,
    #[arg(long)]
    pub to_config: Option<String>,
}

pub fn run(args: Args, ctx: CommandContext) -> Result<()> {
    let request: CDiffRequest = DiffRequest {
        base: RequestBase {
            on_hook: None,
            hook_ctx: null_mut(),
            cancel_token: cancel_token_ptr(),
        },
        from_prefix_digest: args.from_prefix,
        to_prefix_digest: args.to_prefix,
        from_config_digest: args.from_config,
        to_config_digest: args.to_config,
    }
    .into();

    let response = invoke_with_response(|out, error| unsafe { (ctx.lib.ro.diff)(request, out, error) })?;

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

    for entry in unsafe { response.unattached_files.as_slice() } {
        let path = <&str>::try_from(&entry.common.path).unwrap_or_default();
        let source = match entry.source {
            DiffFileSource::Prefix => "prefix",
            DiffFileSource::Config => "config",
        };

        let (marker, colored_path) = match entry.common.kind {
            FileDiffKind::Added => ("+".green().bold(), path.green()),
            FileDiffKind::Removed => ("-".red().bold(), path.red()),
            FileDiffKind::Modified => ("~".yellow().bold(), path.yellow()),
        };

        println!("{} {} ({source})", marker, colored_path.bold());
    }

    unsafe { response.free() };

    Ok(())
}
