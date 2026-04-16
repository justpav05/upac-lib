// ── Imports ─────────────────────────────────────────────────────────────────
use anyhow::Result;

use colored::Colorize;

use indicatif::ProgressBar;

use std::ffi::c_void;
use std::fs;

use crate::backends::PackageMeta;
use crate::config::Config;
use crate::ffi::CSlice;
use crate::upac::{UpacLib, UpacLibGuard};

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
    files: Vec<String>,
    backend: Option<String>,
    checksums: Vec<String>,

    prepared_packages: Vec<PreparedPackage>,
    tmp_dirs: Vec<String>,

    progress_bar: Option<ProgressBar>,

    upac_lib: Option<UpacLibGuard>,
    config: Config,
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
            files,
            backend,
            checksums,
            prepared_packages: Vec::new(),
            tmp_dirs: Vec::new(),
            progress_bar: None,
            upac_lib: None,
            config,
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

    let mut install_machine = InstallMachine::new(config, args.files, args.backend, args.checksums);

    state_preparing_package(&mut install_machine).map_err(|err| {
        if !matches!(install_machine.stack.last(), Some(State::Failed(_))) {
            install_machine.enter(State::Failed(err.to_string()));
        }
        if install_machine.config.verbose {
            eprintln!(
                "{} failed at state {:?}",
                "✗".red().bold(),
                install_machine.stack.last()
            );
        }
        err
    })
}

// ── Helpers ───────────────────────────────────────────────────────────────────
pub unsafe extern "C" fn on_install_progress(event: u8, package_name: CSlice, ctx: *mut c_void) {
    let pb = &*(ctx as *const ProgressBar);
    let name = unsafe { package_name.as_str() };

    match event {
        0 => pb.set_message(format!("verifying {name}...")),
        1 => pb.set_message("opening repo...".to_string()),
        2 => pb.set_message(format!("checking if {name} is installed...")),
        3 => pb.set_message(format!("writing database for {name}...")),
        4 => pb.set_message(format!("processing files for {name}...")),
        5 => pb.set_message(format!("committing {name}...")),
        6 => pb.println(format!("{} {name} ready", "✓".green().bold())),
        7 => pb.println(format!("{} {name} failed", "✗".red().bold())),
        _ => {}
    }
}
