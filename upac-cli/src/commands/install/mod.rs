// ── Imports ─────────────────────────────────────────────────────────────────
use anyhow::Result;

use colored::Colorize;

use indicatif::ProgressBar;

use std::collections::HashMap;
use std::ffi::c_void;
use std::ptr::{null, null_mut};
use std::sync::Arc;

use crate::backends::Backend;
use crate::config::Config;
use crate::ffi::{CPackageEntry, CSlice, PackageMetaHandle};
use crate::types::BackendKind;
use crate::upac::UpacLib;

use self::states::state_preparing_package;

mod states;

// ── Arguments for command ───────────────────────────────────────────────────────────────────────
#[derive(clap::Args)]
pub struct InstallArgs {
    #[arg(required = true, num_args = 1..)]
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

pub struct PreparedPackage {
    pub meta_handle: PackageMetaHandle,
    pub temp_path_c: CSlice,
    pub checksum: String,
    pub backend: Arc<Backend>,
}

impl PreparedPackage {
    pub fn as_c_entry(&self) -> CPackageEntry {
        CPackageEntry {
            meta: self.meta_handle,
            temp_path: self.temp_path_c,
            checksum: CSlice::from_str(&self.checksum),
        }
    }
}

impl Drop for PreparedPackage {
    fn drop(&mut self) {
        unsafe {
            if !self.meta_handle.is_null() {
                (self.backend.backend_meta_free)(self.meta_handle);
                self.meta_handle = null_mut();
            }
            if !self.temp_path_c.ptr.is_null() {
                (self.backend.backend_cleanup)(self.temp_path_c);
                self.temp_path_c = CSlice {
                    ptr: null(),
                    len: 0,
                };
            }
        }
    }
}

// ── FSM machine ───────────────────────────────────────────────────────────────────────
struct InstallMachine {
    files: Vec<String>,
    backend: Option<String>,
    checksums: Vec<String>,

    prepared_packages: Vec<PreparedPackage>,

    upac_lib: Arc<UpacLib>,
    loaded_backends: HashMap<BackendKind, Arc<Backend>>,
    progress_bar: ProgressBar,
    config: Config,
    stack: Vec<State>,
}

impl InstallMachine {
    fn new(
        config: Config,
        files: Vec<String>,
        backend: Option<String>,
        checksums: Vec<String>,
    ) -> Result<Self> {
        Ok(Self {
            files,
            backend,
            checksums,
            prepared_packages: Vec::new(),
            progress_bar: ProgressBar::new_spinner(),
            upac_lib: Arc::new(UpacLib::load(&BackendKind::UpacLib)?),
            loaded_backends: HashMap::new(),
            config,
            stack: Vec::new(),
        })
    }

    fn enter(&mut self, state: State) {
        self.stack.push(state);
    }
}

// ── Public API ─────────────────────────────────────────────────────────────
pub fn run(config: Config, args: InstallArgs) -> Result<()> {
    if !args.checksums.is_empty() && args.checksums.len() != args.files.len() {
        anyhow::bail!(
            "Count of checksums ({}) must match count of files ({})",
            args.checksums.len(),
            args.files.len()
        );
    }

    let mut install_machine =
        InstallMachine::new(config, args.files, args.backend, args.checksums)?;

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
pub unsafe extern "C" fn on_install_progress(event: u8, package_name_c: CSlice, ctx: *mut c_void) {
    let progress_bar = &*(ctx as *const ProgressBar);

    let package_name = unsafe { package_name_c.as_str() };

    match event {
        0 => progress_bar.set_message(format!("Verifying {package_name}...")),
        1 => progress_bar.set_message(format!("Checking free space for {package_name}...")),
        2 => progress_bar.set_message("Opening repo...".to_string()),
        3 => progress_bar.set_message(format!("Checking {package_name} was installed...")),
        4 => progress_bar.set_message(format!("Writing database for {package_name}...")),
        5 => progress_bar.set_message(format!("Writing files for {package_name}...")),
        6 => progress_bar.set_message(format!("Committing {package_name}...")),
        7 => progress_bar.set_message(format!("Checking out {package_name}...")),
        8 => {}
        9 => {}

        10 => progress_bar.println(format!("{} Done", "✓".green().bold())),
        11 => progress_bar.println(format!("{} Failed", "✗".red().bold())),
        _ => {
            eprintln!("Unknow event: {}", event);
            return;
        }
    }
}
