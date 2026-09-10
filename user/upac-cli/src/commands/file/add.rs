// SPDX-FileCopyrightText: 2026 JustPav
// SPDX-FileCopyrightText: 2026 SmoothTeam
//
// SPDX-License-Identifier: GPL-3.0-only

use anyhow::Result;

use clap::Args as ClapArgs;

use i18n_embed_fl::fl;

use upac_abi::FileDiffKind;
use upac_abi::error::ErrorDomain;
use upac_abi::package::CPackageInfo;
use upac_abi::request::CFilesRequest;

use upac_types::package::PackageInfo;
use upac_types::request::{FilesRequest, RequestBase};
use upac_types::settings::RuntimeSettings;

use crate::cancel_token_ptr;
use crate::locale::LOADER;
use crate::types::CommandContext;
use crate::types::abi::{FileScope, invoke};
use crate::types::progress::{ProgressState, on_progress};

#[derive(ClapArgs)]
pub struct Args {
    #[arg(required = true, num_args = 1..)]
    pub files: Vec<String>,
    #[arg(long, required = true)]
    pub package: String,
    #[arg(long, required = true)]
    pub arch: String,
    #[arg(long)]
    pub arch_sub: Option<String>,
    #[arg(short, long)]
    pub message: Option<String>,
    #[arg(long)]
    pub boot: Option<String>,
    #[arg(long, value_enum, default_value_t = FileScope::Usr)]
    pub scope: FileScope,
}

pub fn run(args: Args, ctx: CommandContext) -> Result<()> {
    let symbols = ctx.lib.require_write()?;

    let package: CPackageInfo = PackageInfo {
        name: args.package,
        arch: args.arch,
        arch_sub: args.arch_sub,
    }
    .into();

    let mut progress = ProgressState::new(ErrorDomain::Files);

    let boot_plugin = args
        .boot
        .or_else(|| RuntimeSettings::load().boot.plugin)
        .ok_or_else(|| anyhow::anyhow!(fl!(LOADER, "err-boot-plugin-required")))?;

    let request: CFilesRequest = FilesRequest {
        base: RequestBase {
            on_hook: Some(on_progress),
            hook_ctx: progress.ctx_ptr(),
            cancel_token: cancel_token_ptr(),
        },
        tmp_path: ctx.tmp_path.to_string_lossy().into_owned(),
        subject: "file add".to_owned(),
        message: args.message,
        files: args.files,
        file_kind: FileDiffKind::Added,
        scope: args.scope.into(),
        file_package: &package,
        boot_plugin: boot_plugin,
    }
    .into();

    let result = invoke(|error| unsafe { (symbols.files)(request, error) });
    progress.finish();

    result
}
