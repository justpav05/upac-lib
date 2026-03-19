use anyhow::Result;

use clap::{Parser, Subcommand};

use colored::Colorize;

mod backends;
mod config;
mod ffi;
mod commands {
    pub mod init;
    pub mod install;
    pub mod list;
    pub mod remove;
    pub mod rollback;
}

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
        full: bool,
    },

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

    let config = match &cli.command {
        Command::Init { .. } => None,
        _ => Some(config::Config::load()?),
    };

    match cli.command {
        Command::Install {
            file,
            backend,
            checksum,
        } => {
            commands::install::run(config.unwrap(), file, backend, checksum)?;
        }
        Command::Remove { name } => {
            commands::remove::run(config.unwrap(), name)?;
        }
        Command::List { versions, full } => {
            commands::list::run(config.unwrap(), versions, full)?;
        }
        Command::Rollback { commit } => {
            commands::rollback::run(config.unwrap(), commit)?;
        }
        Command::Init { mode } => {
            commands::init::run(mode)?;
        }
    }

    Ok(())
}
