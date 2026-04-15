use anyhow::Result;

use clap::{Parser, Subcommand};

use colored::Colorize;

use std::path::Path;

mod backends;
mod config;
mod ffi;
mod commands {
    pub mod commit;

    pub mod install;
    pub mod remove;
    pub mod rollback;

    pub mod diff;
    pub mod list;

    pub mod init;
}

const CONFIG_PATH: &str = "/etc/upac/config.toml";

// ── CLI аргументы ─────────────────────────────────────────────────────────────
#[derive(Parser)]
#[command(name = "upac", about = "A modular Linux package manager", version)]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    Install {
        files: Vec<String>,

        #[arg(long)]
        backend: Option<String>,

        #[arg(long, num_args = 0..)]
        checksums: Vec<String>,
    },

    Remove {
        name: Vec<String>,
    },

    Rollback {
        commit: String,
    },

    List {
        #[arg(long)]
        commit: bool,

        #[arg(long)]
        full: bool,
    },

    Diff {
        from: Option<String>,
        to: Option<String>,
        #[arg(long)]
        files: bool,
    },

    Commit,

    Init {
        #[arg(long, default_value = "archive")]
        mode: String,
    },
}

// ── Точка входа ───────────────────────────────────────────────────────────────
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
        Command::Install {
            files,
            backend,
            checksums,
        } => {
            commands::install::run(config, files, backend, checksums)?;
        }
        Command::Remove { name } => {
            commands::remove::run(config, name)?;
        }
        Command::Commit => {
            commands::commit::run(config)?;
        }
        Command::List { commit, full } => {
            commands::list::run(config, commit, full)?;
        }
        Command::Diff { from, to, files } => {
            commands::diff::run(config, from, to, files)?;
        }
        Command::Rollback { commit } => {
            commands::rollback::run(config, commit)?;
        }
        Command::Init { mode } => {
            commands::init::run(config, mode)?;
        }
    }

    Ok(())
}
