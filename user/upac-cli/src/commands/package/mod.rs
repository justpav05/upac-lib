// SPDX-FileCopyrightText: 2026 JustPav
// SPDX-FileCopyrightText: 2026 SmoothTeam
//
// SPDX-License-Identifier: GPL-3.0-only

use anyhow::Result;

use clap::{Args, Subcommand};

use crate::types::CommandContext;

pub mod diff;
pub mod install;
pub mod list;
pub mod remove;
pub mod search;
pub mod update;

#[derive(Args)]
pub struct PkgArgs {
    #[command(subcommand)]
    pub command: PkgCommand,
}

#[derive(Subcommand)]
pub enum PkgCommand {
    Install(install::Args),
    #[command(alias = "uninstall")]
    Remove(remove::Args),
    Update(update::Args),
    List(list::Args),
    Diff(diff::Args),
    Search(search::Args),
}

pub fn run(args: PkgArgs, context: CommandContext) -> Result<()> {
    match args.command {
        PkgCommand::Install(args) => install::run(args, context),
        PkgCommand::Remove(args) => remove::run(args, context),
        PkgCommand::Update(args) => update::run(args, context),
        PkgCommand::List(args) => list::run(args, context),
        PkgCommand::Diff(args) => diff::run(args, context),
        PkgCommand::Search(args) => search::run(args, context),
    }
}
