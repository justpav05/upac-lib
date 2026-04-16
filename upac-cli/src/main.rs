// ── Imports ─────────────────────────────────────────────────────────────────
use anyhow::Result;

use clap::{Parser, Subcommand};

use colored::Colorize;

use std::path::Path;

use commands::diff::DiffArgs;
use commands::init::InitArgs;
use commands::install::InstallArgs;
use commands::list::ListArgs;
use commands::remove::RemoveArgs;
use commands::rollback::RollbackArgs;

mod backends;
mod config;
mod ffi;
mod commands {
    pub mod install;
    pub mod remove;
    pub mod rollback;

    pub mod diff;
    pub mod list;

    pub mod init;
}

const CONFIG_PATH: &str = "/etc/upac/config.toml";

// ── CLI arguments ─────────────────────────────────────────────────────────────
#[derive(Parser)]
#[command(name = "upac", about = "A modular Linux package manager", version)]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    Install(InstallArgs),
    Remove(RemoveArgs),
    Rollback(RollbackArgs),

    List(ListArgs),
    Diff(DiffArgs),
    Init(InitArgs),
}

// ── Entry point ───────────────────────────────────────────────────────────────
fn main() {
    if let Err(err) = run() {
        eprintln!("{} {err}", "error:".red().bold());
        std::process::exit(1);
    }
}

fn run() -> Result<()> {
    let cli = Cli::parse();

    let default_config_path = Path::new(CONFIG_PATH);
    let config = config::Config::load(&default_config_path)?;

    match cli.command {
        Command::Install(args) => {
            commands::install::run(config, args)?;
        }
        Command::Remove(args) => {
            commands::remove::run(config, args)?;
        }
        Command::List(args) => {
            commands::list::run(config, args)?;
        }
        Command::Diff(args) => {
            commands::diff::run(config, args)?;
        }
        Command::Rollback(args) => {
            commands::rollback::run(config, args)?;
        }
        Command::Init(args) => {
            commands::init::run(config, args)?;
        }
    }

    Ok(())
}
