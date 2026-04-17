// ── Imports ─────────────────────────────────────────────────────────────────
use anyhow::Result;

use colored::Colorize;

use indicatif::ProgressBar;

use std::ffi::c_void;
use std::fs;

use crate::backends::{BackendLibGuard, PackageMeta};
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

#[repr(u8)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum InstallProgressEvent {
    Verifying = 0,
    OpeningRepo = 1,
    CheckingInstalled = 2,
    WritingDatabase = 3,
    ProcessingFiles = 4,
    Committing = 5,
    Ready = 6,
    Failed = 7,
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
    backend_lib: Option<BackendLibGuard>,
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
            backend_lib: None,
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
pub unsafe extern "C" fn on_install_progress(
    event_raw: u8,
    package_name_c: CSlice,
    ctx: *mut c_void,
) {
    let progress_bar = &*(ctx as *const ProgressBar);
    let event: InstallProgressEvent = std::mem::transmute(event_raw);

    let package_name = unsafe { package_name_c.as_str() };

    match event {
        InstallProgressEvent::Verifying => {
            progress_bar.set_message(format!("verifying {package_name}..."))
        }
        InstallProgressEvent::OpeningRepo => {
            progress_bar.set_message("opening repo...".to_string())
        }
        InstallProgressEvent::CheckingInstalled => {
            progress_bar.set_message(format!("checking if {package_name} is installed..."))
        }
        InstallProgressEvent::WritingDatabase => {
            progress_bar.set_message(format!("writing database for {package_name}..."))
        }
        InstallProgressEvent::ProcessingFiles => {
            progress_bar.set_message(format!("processing files for {package_name}..."))
        }
        InstallProgressEvent::Committing => {
            progress_bar.set_message(format!("committing {package_name}..."))
        }
        InstallProgressEvent::Ready => {
            progress_bar.println(format!("{} {package_name}done", "✓".green().bold()))
        }
        InstallProgressEvent::Failed => {
            progress_bar.println(format!("{} {package_name}failed", "✗".red().bold()))
        }
    }
}
