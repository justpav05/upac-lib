use anyhow::Result;

use colored::Colorize;

use indicatif::{ProgressBar, ProgressStyle};

use sha2::{Digest, Sha256};

use std::fs;
use std::io::Read;
use std::process;
use std::time::Duration;

use crate::backends::{Backend, BackendKind, PackageMeta};

use crate::config::Config;
use crate::ffi::{CInstallRequest, CPackageEntry, CSlice, UpacLib, UpacLibGuard};

// ── FSM ───────────────────────────────────────────────────────────────────────
#[derive(Debug, Clone, PartialEq)]
enum State {
    DetectingBackend(String),
    PreparingPackage,
    Installing,
    Done,
    Failed(String),
}

struct PreparedPackage {
    meta: PackageMeta,
    temp_path: String,
    checksum: String,
}

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

// ── Состояния ─────────────────────────────────────────────────────────────────
fn state_preparing_package(machine: &mut InstallMachine) -> Result<()> {
    machine.enter(State::PreparingPackage);

    let files: Vec<String> = machine.files.clone();

    for (index, file) in files.iter().enumerate() {
        let kind = if let Some(flag) = &machine.backend {
            BackendKind::from_flag(flag)?
        } else {
            BackendKind::detect(file).ok_or_else(|| {
                anyhow::anyhow!("cannot detect backend for '{file}'. Use --backend to specify one")
            })?
        };

        machine.enter(State::DetectingBackend(file.clone()));
        println!("{} backend: {:?}", "→".cyan(), kind);

        let progress_bar = spinner("Verifying and extracting package...");

        let tmp_string_path = format!("/tmp/upac_install_{}_{}", process::id(), index);
        fs::remove_dir_all(&tmp_string_path).ok();
        fs::create_dir_all(&tmp_string_path)?;
        machine.tmp_dirs.push(tmp_string_path.clone());

        let backend = Backend::load(&kind)?;

        let abs_file = fs::canonicalize(file)
            .map_err(|err| anyhow::anyhow!("cannot resolve path '{file}': {err}"))?;
        let abs_file_str = abs_file
            .to_str()
            .ok_or_else(|| anyhow::anyhow!("invalid path encoding"))?
            .to_owned();

        let checksum = if machine.checksums.is_empty() {
            compute_checksum(&abs_file_str)?
        } else {
            machine.checksums[index].clone()
        };

        let package_meta = backend
            .prepare(&abs_file_str, &tmp_string_path, &checksum)
            .map_err(|err| {
                progress_bar.finish_and_clear();
                err
            })?;

        progress_bar.finish_and_clear();

        machine.prepared_packages.push(PreparedPackage {
            meta: package_meta,
            temp_path: tmp_string_path,
            checksum,
        });
    }

    state_installing(machine)
}

fn state_installing(machine: &mut InstallMachine) -> Result<()> {
    machine.enter(State::Installing);

    let progress_bar = spinner("Installing...");

    let upac_lib = UpacLibGuard::load()?;

    let c_entries: Vec<CPackageEntry> = machine
        .prepared_packages
        .iter()
        .map(|pkg| CPackageEntry {
            meta: pkg.meta.as_c(),
            temp_path: CSlice::from_str(&pkg.temp_path),
            checksum: CSlice::from_str(&pkg.checksum),
        })
        .collect();

    let c_install_request = CInstallRequest {
        packages: c_entries.as_ptr(),
        packages_len: c_entries.len(),

        repo_path: CSlice::from_str(&machine.config.paths.repo_path),
        root_path: CSlice::from_str(&machine.config.paths.root_path),
        db_path: CSlice::from_str(&machine.config.paths.database_path),
        branch: CSlice::from_str(&machine.config.ostree.branch),
        max_retries: machine.config.step_retries,
    };

    let return_code = unsafe { (upac_lib.install)(c_install_request) };

    progress_bar.finish_and_clear();
    UpacLib::check(return_code, "install")?;

    state_done(machine)
}

fn state_done(machine: &mut InstallMachine) -> Result<()> {
    machine.enter(State::Done);

    for pkg in &machine.prepared_packages {
        println!(
            "{} installed {} {}",
            "✓".green().bold(),
            pkg.meta.name.bold(),
            pkg.meta.version.dimmed()
        );
    }

    Ok(())
}

// ── Публичное API ─────────────────────────────────────────────────────────────
pub fn run(
    config: Config,
    files: Vec<String>,
    backend: Option<String>,
    checksums: Vec<String>,
) -> Result<()> {
    if !checksums.is_empty() && checksums.len() != files.len() {
        anyhow::bail!(
            "number of checksums ({}) must match number of files ({})",
            checksums.len(),
            files.len()
        );
    }

    let mut machine = InstallMachine::new(config, files, backend, checksums);

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

// ── Хелперы ───────────────────────────────────────────────────────────────────
fn spinner(message: &str) -> ProgressBar {
    let progress_bar = ProgressBar::new_spinner();
    progress_bar.set_style(
        ProgressStyle::default_spinner()
            .tick_strings(&["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"])
            .template("{spinner:.cyan} {msg}")
            .unwrap(),
    );
    progress_bar.set_message(message.to_owned());
    progress_bar.enable_steady_tick(Duration::from_millis(80));
    progress_bar
}

fn compute_checksum(file_path: &str) -> Result<String> {
    let mut file =
        fs::File::open(file_path).map_err(|err| anyhow::anyhow!("failed to open file: {err}"))?;

    let mut hasher = Sha256::new();
    let mut buffer = [0u8; 4096];

    loop {
        let bytes_read = file.read(&mut buffer)?;
        if bytes_read == 0 {
            break;
        }
        hasher.update(&buffer[..bytes_read]);
    }

    Ok(hex::encode(hasher.finalize()))
}
