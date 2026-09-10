// SPDX-FileCopyrightText: 2026 JustPav
// SPDX-FileCopyrightText: 2026 SmoothTeam
//
// SPDX-License-Identifier: GPL-3.0-only

// ── Imports ─────────────────────────────────────────────────────────────────
use std::process::ExitCode;

use anyhow::Result;

use clap::Parser;

use colored::Colorize;

use i18n_embed_fl::fl;

mod commands {
    pub mod generate_cert;
    pub mod generate_root;
    pub mod sign_hook;
    pub mod verify_hook;
}

mod errors;
mod layout {
    include!(concat!(env!("OUT_DIR"), "/layout.rs"));
}
mod locale;

#[derive(Parser)]
#[command(name = "up-si", author, version, about)]
enum Command {
    GenerateRoot(commands::generate_root::Args),
    GenerateCert(commands::generate_cert::Args),
    SignHook(commands::sign_hook::Args),
    VerifyHook(commands::verify_hook::Args),
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
    match Command::parse() {
        Command::GenerateRoot(args) => commands::generate_root::run(args)?,
        Command::GenerateCert(args) => commands::generate_cert::run(args)?,
        Command::SignHook(args) => commands::sign_hook::run(args)?,
        Command::VerifyHook(args) => commands::verify_hook::run(args)?,
    }

    Ok(())
}
