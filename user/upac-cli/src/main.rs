// SPDX-FileCopyrightText: 2026 JustPav
// SPDX-FileCopyrightText: 2026 SmoothTeam
//
// SPDX-License-Identifier: GPL-3.0-only

use std::process::ExitCode;
use std::ptr::addr_of_mut;
use std::sync::Arc;

use colored::Colorize;

use anyhow::Result;

use clap::Parser;

use i18n_embed_fl::fl;

use upac_abi::hook::CancelToken;

use self::commands::commit::CommitArgs;
use self::commands::file::FileArgs;
use self::commands::package::PkgArgs;
use self::libcore::Lib;
use self::types::CommandContext;

mod libcore;
mod layout {
    include!(concat!(env!("OUT_DIR"), "/layout.rs"));
}
mod locale;
mod types;

mod commands {
    pub mod commit;
    pub mod diff;
    pub mod display;
    pub mod file;
    pub mod gc;
    pub mod mime;
    pub mod package;
    pub mod rollback;
}

static mut CANCEL_TOKEN: CancelToken = CancelToken::new();

pub(crate) fn cancel_token_ptr() -> *mut CancelToken {
    addr_of_mut!(CANCEL_TOKEN)
}

#[derive(Parser)]
#[command(author, version, about)]
enum Command {
    Pkg(PkgArgs),
    Commit(CommitArgs),
    File(FileArgs),
    Gc(commands::gc::Args),
    Diff(commands::diff::Args),
    Mime(commands::mime::MimeArgs),
    Rollback(commands::rollback::Args),
}

fn main() -> ExitCode {
    locale::init();

    match run() {
        Ok(()) => ExitCode::SUCCESS,
        Err(err) => {
            eprintln!("{} {err}", format!("{}:", fl!(locale::LOADER, "error")).red().bold());
            ExitCode::FAILURE
        }
    }
}

fn run() -> Result<()> {
    let lib = Arc::new(Lib::load()?);

    let lib_cancel = Arc::clone(&lib);

    ctrlc::set_handler(move || {
        unsafe { (lib_cancel.cancel)(cancel_token_ptr()) };
    })?;

    let command_context = CommandContext::new(lib)?;

    match Command::parse() {
        Command::Pkg(args) => commands::package::run(args, command_context)?,
        Command::Commit(args) => commands::commit::run(args, command_context)?,
        Command::File(args) => commands::file::run(args, command_context)?,
        Command::Gc(args) => commands::gc::run(args, command_context)?,
        Command::Diff(args) => commands::diff::run(args, command_context)?,
        Command::Mime(args) => commands::mime::run(args, command_context)?,
        Command::Rollback(args) => commands::rollback::run(args, command_context)?,
    }

    Ok(())
}
