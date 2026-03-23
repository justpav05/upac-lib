use anyhow::Result;

use clap::{Parser, Subcommand};

use colored::Colorize;

use std::path::Path;

mod backends;
mod config;
mod ffi;
mod commands {
    pub mod commit;
    pub mod init;
    pub mod install;
    pub mod list;
    pub mod remove;
    pub mod rollback;
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
        file: String,

        #[arg(long)]
        backend: Option<String>,

        #[arg(long)]
        checksum: Option<String>,
    },

    Remove {
        name: String,
    },

    List {
        #[arg(long)]
        versions: bool,

        #[arg(long)]
        commit: bool,

        #[arg(long)]
        full: bool,
    },

    Commit,

    Rollback {
        commit: String,
    },

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
            file,
            backend,
            checksum,
        } => {
            commands::install::run(config, file, backend, checksum)?;
        }
        Command::Remove { name } => {
            commands::remove::run(config, name)?;
        }
        Command::List {
            versions,
            commit,
            full,
        } => {
            commands::list::run(config, versions, commit, full)?;
        }
        Command::Commit => {
            commands::commit::run(config)?;
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
