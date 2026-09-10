// SPDX-FileCopyrightText: 2026 JustPav
// SPDX-FileCopyrightText: 2026 SmoothTeam
//
// SPDX-License-Identifier: GPL-3.0-only

use anyhow::Result;

use clap::{Args, Subcommand};

use crate::types::CommandContext;

pub mod sync;

#[derive(Args)]
pub struct MimeArgs {
    #[command(subcommand)]
    pub command: MimeCommand,
}

#[derive(Subcommand)]
pub enum MimeCommand {
    Sync(sync::Args),
}

pub fn run(args: MimeArgs, context: CommandContext) -> Result<()> {
    match args.command {
        MimeCommand::Sync(args) => sync::run(args, context),
    }
}
