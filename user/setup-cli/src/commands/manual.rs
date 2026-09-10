// SPDX-FileCopyrightText: 2026 JustPav
// SPDX-FileCopyrightText: 2026 SmoothTeam
//
// SPDX-License-Identifier: GPL-3.0-only

use anyhow::Result;

use clap::Args as ClapArgs;

use upac_abi::hook::CancelToken;

use upac_setup::data::SetupExistingData;

use upac_types::PartitionMount;

use crate::errors::LocalizedSetupError;
use crate::progress::{ProgressState, on_progress};
use crate::types::{FsKind, parse_extra_mount};

#[derive(ClapArgs)]
pub struct Args {
    #[arg(long)]
    pub esp_device: String,
    #[arg(long)]
    pub deploy_device: String,
    #[arg(long, value_enum)]
    pub deploy_fs: FsKind,
    #[arg(long = "extra-mount", value_parser = parse_extra_mount)]
    pub extra_mounts: Vec<PartitionMount>,

    #[arg(long)]
    pub mount_point: Option<String>,
    #[arg(long)]
    pub source: String,
    #[arg(long)]
    pub empty_config: bool,
    #[arg(long)]
    pub pinned: bool,
    #[arg(long)]
    pub boot_plugin: Option<String>,
}

pub fn run(args: Args, cancel_token: &CancelToken) -> Result<()> {
    let mut progress = ProgressState::new();

    let data = SetupExistingData {
        esp_device: &args.esp_device,
        deploy_device: &args.deploy_device,
        deploy_fs: args.deploy_fs.into(),
        extra_mounts: args.extra_mounts,

        mount_point: args.mount_point.as_deref(),
        source: &args.source,
        empty_config: args.empty_config,
        pinned: args.pinned,
        boot_plugin: args.boot_plugin.as_deref(),

        hook_message: Some(on_progress),
        hook_message_context: progress.ctx_ptr(),

        cancel_token,
    };

    let result = data.run();
    progress.finish();

    result.map_err(LocalizedSetupError)?;

    Ok(())
}
