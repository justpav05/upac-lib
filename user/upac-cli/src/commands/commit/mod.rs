// SPDX-FileCopyrightText: 2026 JustPav
// SPDX-FileCopyrightText: 2026 SmoothTeam
//
// SPDX-License-Identifier: GPL-3.0-only

use anyhow::Result;

use clap::{Args, Subcommand};

use crate::types::CommandContext;

pub mod diff;
pub mod history;
pub mod list;
pub mod new;
pub mod pin;
pub mod prefixes;
pub mod unpin;

#[derive(Args)]
pub struct CommitArgs {
    #[command(subcommand)]
    pub command: CommitCommand,
}

#[derive(Subcommand)]
pub enum CommitCommand {
    Diff(diff::Args),
    History(history::Args),
    List(list::Args),
    New(new::Args),
    Pin(pin::Args),
    Prefixes(prefixes::Args),
    Unpin(unpin::Args),
}

pub fn run(args: CommitArgs, context: CommandContext) -> Result<()> {
    match args.command {
        CommitCommand::Diff(args) => diff::run(args, context),
        CommitCommand::History(args) => history::run(args, context),
        CommitCommand::List(args) => list::run(args, context),
        CommitCommand::New(args) => new::run(args, context),
        CommitCommand::Pin(args) => pin::run(args, context),
        CommitCommand::Prefixes(args) => prefixes::run(args, context),
        CommitCommand::Unpin(args) => unpin::run(args, context),
    }
}
