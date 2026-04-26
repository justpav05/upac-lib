// ── Imports ─────────────────────────────────────────────────────────────────
use anyhow::Result;

use clap::{Parser, Subcommand};

use colored::Colorize;

use std::fs;
use std::path::{Path, PathBuf};
use std::thread::Builder;

use commands::diff::DiffArgs;
use commands::init::InitArgs;
use commands::install::InstallArgs;
use commands::list::ListArgs;
use commands::remove::RemoveArgs;
use commands::rollback::RollbackArgs;

use config::Config;

mod backends;
mod config;
mod upac;

pub mod ffi;
pub mod types;

mod commands {
    pub mod install;
    pub mod remove;
    pub mod rollback;

    pub mod diff;
    pub mod list;

    pub mod init;
}

// ── CLI arguments ─────────────────────────────────────────────────────────────
// Automatic generation of Cli structure parser
#[derive(Parser)]
#[command(name = "upac", about = "A modular Linux package manager", version)]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

// Enumerate all available CLI subcommands
#[derive(Subcommand)]
enum Command {
    Install(InstallArgs),
    Remove(RemoveArgs),
    Rollback(RollbackArgs),

    List(ListArgs),
    Diff(DiffArgs),
    Init(InitArgs),
}

// ── Entry points ───────────────────────────────────────────────────────────────
// The main entry point, responsible for error output and the return code.
fn main() {
    let result = Builder::new()
        .name("upac-main".into())
        .stack_size(64 * 1024 * 1024) // 64 MiB
        .spawn(|| run())
        .expect("Failed to spawn main thread")
        .join()
        .expect("Main thread panicked");

    match result {
        Ok(()) => {}
        Err(err) if err.to_string().contains("cancelled") => {
            eprintln!("\n{} Cancelled", "!".yellow().bold());
            std::process::exit(130);
        }
        Err(err) => {
            eprintln!("{} {err}", "Error:".red().bold());
            std::process::exit(1);
        }
    }
}

// Core business logic: argument parsing, config loading, and command execution
fn run() -> Result<()> {
    let cli = Cli::parse();
    ctrlc::set_handler(move || {
        println!(
            "\n{} Abort signal received, exiting...",
            "!".yellow().bold()
        );
    })?;

    let default_config_path =
        check_default_config_path().ok_or(anyhow::anyhow!("no default config path found"))?;
    let config = Config::load(&default_config_path)?;

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

// ── Helpers ───────────────────────────────────────────────────────────────────
// Standard path validation function
fn check_default_config_path() -> Option<PathBuf> {
    let path = Path::new("/etc/upac/config.toml");

    if fs::metadata(path).is_ok() {
        Some(path.to_path_buf())
    } else {
        None
    }
}
