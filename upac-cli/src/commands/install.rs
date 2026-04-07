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
use crate::ffi::{CInstallRequest, CSlice, UpacLib};

// ── FSM ───────────────────────────────────────────────────────────────────────
#[derive(Debug, Clone, PartialEq)]
enum State {
    DetectingBackend,
    PreparingPackage,
    Installing,
    Done,
    Failed(String),
}

struct InstallMachine {
    config: Config,
    file: String,
    backend: Option<String>,
    checksum: String,

    kind: Option<BackendKind>,
    tmp_dir: Option<String>,
    package_meta: Option<PackageMeta>,

    stack: Vec<State>,
}

impl InstallMachine {
    fn new(config: Config, file: String, backend: Option<String>, checksum: String) -> Self {
        Self {
            config,
            file,
            backend,
            checksum,
            kind: None,
            tmp_dir: None,
            package_meta: None,
            stack: Vec::new(),
        }
    }

    fn enter(&mut self, state: State) {
        self.stack.push(state);
    }
}

impl Drop for InstallMachine {
    fn drop(&mut self) {
        if let Some(tmp) = &self.tmp_dir {
            let _ = std::fs::remove_dir_all(tmp);
        }
    }
}

// ── Состояния ─────────────────────────────────────────────────────────────────
fn state_detecting_backend(install_machine: &mut InstallMachine) -> Result<()> {
    install_machine.enter(State::DetectingBackend);

    let kind = if let Some(flag) = &install_machine.backend.clone() {
        BackendKind::from_flag(flag)?
    } else {
        BackendKind::detect(&install_machine.file).ok_or_else(|| {
            anyhow::anyhow!(
                "cannot detect backend for '{}'. Use --backend to specify one",
                install_machine.file
            )
        })?
    };

    println!("{} backend: {:?}", "→".cyan(), kind);
    install_machine.kind = Some(kind);

    state_preparing_package(install_machine)
}

fn state_preparing_package(install_machine: &mut InstallMachine) -> Result<()> {
    install_machine.enter(State::PreparingPackage);

    let progress_bar = spinner("Verifying and extracting package...");

    let tmp_string_path = format!("/tmp/upac_install_{}", process::id());

    fs::remove_dir_all(&tmp_string_path).ok();
    fs::create_dir_all(&tmp_string_path)?;

    install_machine.tmp_dir = Some(tmp_string_path.clone());

    let backend = Backend::load(install_machine.kind.as_ref().unwrap())?;

    let abs_file = fs::canonicalize(&install_machine.file)
        .map_err(|err| anyhow::anyhow!("cannot resolve path '{}': {err}", install_machine.file))?;
    let abs_file_str = abs_file
        .to_str()
        .ok_or_else(|| anyhow::anyhow!("invalid path encoding"))?
        .to_owned();

    let package_meta = backend
        .prepare(&abs_file_str, &tmp_string_path, &install_machine.checksum)
        .map_err(|err| {
            progress_bar.finish_and_clear();
            err
        })?;

    progress_bar.finish_and_clear();
    println!(
        "{} {} {}",
        "✓".green().bold(),
        package_meta.name.bold(),
        package_meta.version.dimmed()
    );

    install_machine.package_meta = Some(package_meta);

    state_installing(install_machine)
}

fn state_installing(install_machine: &mut InstallMachine) -> Result<()> {
    install_machine.enter(State::Installing);

    let progress_bar = spinner("Installing...");

    let upac_lib = UpacLib::load()?;

    let package_meta = install_machine.package_meta.as_ref().unwrap();
    let tmp_dir_string_path = install_machine.tmp_dir.as_ref().unwrap();
    let c_package_meta = package_meta.as_c();

    let branch = &install_machine.config.ostree.branch;

    let c_install_request = CInstallRequest {
        meta: c_package_meta,
        package_temp_path: CSlice::from_str(tmp_dir_string_path),
        package_checksum: CSlice::from_str(&install_machine.checksum),
        repo_path: CSlice::from_str(&install_machine.config.paths.repo_path),
        root_path: CSlice::from_str(&install_machine.config.paths.root_path),
        db_path: CSlice::from_str(&install_machine.config.paths.database_path),
        branch: CSlice::from_str(branch),
        max_retries: install_machine.config.step_retries,
    };

    let return_code = unsafe { (upac_lib.install)(c_install_request) };

    progress_bar.finish_and_clear();
    UpacLib::check(return_code, "install")?;

    state_done(install_machine)
}

fn state_done(install_machine: &mut InstallMachine) -> Result<()> {
    install_machine.enter(State::Done);

    let package_meta = install_machine.package_meta.as_ref().unwrap();
    println!(
        "{} installed {} {}",
        "✓".green().bold(),
        package_meta.name.bold(),
        package_meta.version.dimmed()
    );

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

    for (index, file) in files.iter().enumerate() {
        let checksum = if checksums.is_empty() {
            compute_checksum(file)?
        } else {
            checksums[index].clone()
        };

        let mut install_machine =
            InstallMachine::new(config.clone(), file.clone(), backend.clone(), checksum);

        state_detecting_backend(&mut install_machine).map_err(|err| {
            if !matches!(install_machine.stack.last(), Some(State::Failed(_))) {
                install_machine.enter(State::Failed(err.to_string()));
            }
            if config.verbose {
                eprintln!(
                    "{} failed at state {:?}",
                    "✗".red().bold(),
                    install_machine.stack.last()
                );
            }
            err
        })?;
    }

    Ok(())
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

    Ok(format!("{:x}", hasher.finalize()))
}
