// SPDX-FileCopyrightText: 2026 JustPav
// SPDX-FileCopyrightText: 2026 SmoothTeam
//
// SPDX-License-Identifier: GPL-3.0-only

use std::fs::canonicalize;

use anyhow::Result;

use clap::Args as ClapArgs;

use i18n_embed_fl::fl;

use upac_abi::error::ErrorDomain;
use upac_abi::request::CUpdateRequest;

use upac_types::request::{RequestBase, UpdateRequest};
use upac_types::settings::RuntimeSettings;

use crate::cancel_token_ptr;
use crate::locale::LOADER;
use crate::types::CommandContext;
use crate::types::abi::invoke;
use crate::types::progress::{ProgressState, on_progress};

#[derive(ClapArgs)]
pub struct Args {
    #[arg(short, long = "file", required = true, num_args = 1..)]
    pub files: Vec<String>,
    #[arg(short, long)]
    pub message: Option<String>,
    #[arg(long)]
    pub boot: Option<String>,
    #[arg(long)]
    pub allow_downgrade: bool,
    #[arg(long)]
    pub no_conflict_files: bool,
}

pub fn run(args: Args, ctx: CommandContext) -> Result<()> {
    let symbols = ctx.lib.require_write()?;

    let mut packages = Vec::with_capacity(args.files.len());
    for file_path in &args.files {
        let absolute =
            canonicalize(file_path).map_err(|_| anyhow::anyhow!("{}: {file_path}", fl!(LOADER, "err-not-found")))?;
        packages.push(absolute.to_string_lossy().into_owned());
    }

    let mut progress = ProgressState::new(ErrorDomain::Update);

    let boot_plugin = args
        .boot
        .or_else(|| RuntimeSettings::load().boot.plugin)
        .ok_or_else(|| anyhow::anyhow!(fl!(LOADER, "err-boot-plugin-required")))?;

    let request: CUpdateRequest = UpdateRequest {
        base: RequestBase {
            on_hook: Some(on_progress),
            hook_ctx: progress.ctx_ptr(),
            cancel_token: cancel_token_ptr(),
        },
        tmp_path: ctx.tmp_path.to_string_lossy().into_owned(),
        subject: "update".to_owned(),
        message: args.message,
        packages,
        boot_plugin: boot_plugin,
        allow_downgrade: args.allow_downgrade,
        allow_conflict_files: !args.no_conflict_files,
    }
    .into();

    let result = invoke(|error| unsafe { (symbols.update)(request, error) });
    progress.finish();

    result
}
