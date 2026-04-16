// ── Imports ─────────────────────────────────────────────────────────────────
use anyhow::Result;

use colored::Colorize;

use std::fs;

use crate::backends::PackageMeta;
use crate::config::Config;

use self::states::state_preparing_package;

mod states;

// ── Prepared package ───────────────────────────────────────────────────────────────────────
struct PreparedPackage {
    meta: PackageMeta,
    temp_path: String,
    checksum: String,
}

// ── Arguments for command ───────────────────────────────────────────────────────────────────────
#[derive(clap::Args)]
pub struct InstallArgs {
    pub files: Vec<String>,
    #[arg(long)]
    pub backend: Option<String>,
    #[arg(long, num_args = 0..)]
    pub checksums: Vec<String>,
}

// ── FSM states ───────────────────────────────────────────────────────────────────────
#[derive(Debug, Clone, PartialEq)]
enum State {
    DetectingBackend(String),
    PreparingPackage,
    Installing,
    Done,
    Failed(String),
}

// ── FSM machine ───────────────────────────────────────────────────────────────────────
struct InstallMachine {
    config: Config,
    files: Vec<String>,
    backend: Option<String>,
    checksums: Vec<String>,

    prepared_packages: Vec<PreparedPackage>,
    tmp_dirs: Vec<String>,

    stack: Vec<State>,
}

impl InstallMachine {
    fn new(
        config: Config,
        files: Vec<String>,
        backend: Option<String>,
        checksums: Vec<String>,
    ) -> Self {
        Self {
            config,
            files,
            backend,
            checksums,
            prepared_packages: Vec::new(),
            tmp_dirs: Vec::new(),
            stack: Vec::new(),
        }
    }

    fn enter(&mut self, state: State) {
        self.stack.push(state);
    }
}

impl Drop for InstallMachine {
    fn drop(&mut self) {
        for tmp_dir in &self.tmp_dirs {
            let _ = fs::remove_dir_all(tmp_dir);
        }
    }
}

// ── Public API ─────────────────────────────────────────────────────────────
pub fn run(config: Config, args: InstallArgs) -> Result<()> {
    if !args.checksums.is_empty() && args.checksums.len() != args.files.len() {
        anyhow::bail!(
            "number of checksums ({}) must match number of files ({})",
            args.checksums.len(),
            args.files.len()
        );
    }

    let mut machine = InstallMachine::new(config, args.files, args.backend, args.checksums);

    state_preparing_package(&mut machine).map_err(|err| {
        if !matches!(machine.stack.last(), Some(State::Failed(_))) {
            machine.enter(State::Failed(err.to_string()));
        }
        if machine.config.verbose {
            eprintln!(
                "{} failed at state {:?}",
                "✗".red().bold(),
                machine.stack.last()
            );
        }
        err
    })
}
