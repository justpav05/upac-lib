use anyhow::Result;

use colored::Colorize;

use indicatif::{ProgressBar, ProgressStyle};

use std::fs;
use std::process;
use std::ptr;
use std::time::Duration;

use crate::backends::{Backend, BackendKind, PackageMeta};

use crate::config::Config;
use crate::ffi::{CCommitRequest, CInstallRequest, COstreeOperation, CSlice, CSliceArray, UpacLib};

// ── FSM ───────────────────────────────────────────────────────────────────────
#[derive(Debug, Clone, PartialEq)]
enum State {
    DetectingBackend,
    PreparingPackage,
    Installing,
    Committing,
    RollingBack,
    Done,
    Failed(String),
}

struct InstallMachine {
    config: Config,
    file: String,
    backend: Option<String>,
    checksum: String,
    retries: u8,

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
            retries: 0,
            kind: None,
            tmp_dir: None,
            package_meta: None,
            stack: Vec::new(),
        }
    }

    fn enter(&mut self, state: State) {
        self.stack.push(state);
    }

    fn exhausted(&self) -> bool {
        self.retries >= self.config.step_retries
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

    let progress_bar = spinner(&format!(
        "Installing{}...",
        if install_machine.retries > 0 {
            format!(
                " (retry {}/{})",
                install_machine.retries, install_machine.config.step_retries
            )
        } else {
            String::new()
        }
    ));

    let upac_lib = UpacLib::load()?;

    let package_meta = install_machine.package_meta.as_ref().unwrap();

    let tmp_dir_string_path = install_machine.tmp_dir.as_ref().unwrap();

    let c_package_meta = package_meta.as_c();

    let c_install_request = CInstallRequest {
        meta: c_package_meta,
        root_path: CSlice::from_str(&install_machine.config.paths.root_path),
        repo_path: CSlice::from_str(&install_machine.config.paths.repo_path),
        package_path: CSlice::from_str(tmp_dir_string_path),
        db_path: CSlice::from_str(&install_machine.config.paths.database_path),
        max_retries: install_machine.config.step_retries,
    };

    let return_code = unsafe { (upac_lib.install)(c_install_request) };

    progress_bar.finish_and_clear();

    if let Err(err) = UpacLib::check(return_code, "install") {
        return state_rolling_back(install_machine, err.to_string());
    }

    if install_machine.config.ostree.enabled {
        return state_committing(install_machine);
    }

    state_done(install_machine)
}

fn state_committing(install_machine: &mut InstallMachine) -> Result<()> {
    install_machine.enter(State::Committing);

    let progress_bar = spinner("Creating OStree snapshot...");

    let upac_lib = UpacLib::load()?;
    let package_meta = install_machine.package_meta.as_ref().unwrap();
    let c_package_meta = package_meta.as_c();

    let c_commit_request = CCommitRequest {
        repo_path: CSlice::from_str(&install_machine.config.paths.ostree_path),
        content_path: CSlice::from_str(&install_machine.config.paths.repo_path),
        branch: CSlice::from_str(&install_machine.config.ostree.branch),
        operation: COstreeOperation::Install,
        packages: &c_package_meta as *const _,
        packages_len: 1,
        db_path: CSlice::from_str(&install_machine.config.paths.database_path),
    };

    let return_code = unsafe { (upac_lib.ostree_commit)(c_commit_request) };

    progress_bar.finish_and_clear();

    if let Err(err) = UpacLib::check(return_code, "ostree commit") {
        eprintln!("{} ostree snapshot failed: {err}", "⚠".yellow().bold());

        return state_rolling_back(install_machine, err.to_string());
    }

    println!("{} snapshot created", "✓".green().bold());

    state_done(install_machine)
}

fn state_rolling_back(install_machine: &mut InstallMachine, reason: String) -> Result<()> {
    install_machine.enter(State::RollingBack);

    let progress_bar = spinner("Rolling back...");

    if let Some(package_meta) = install_machine.package_meta.as_ref() {
        let repo_package_string_path = format!(
            "{}/{}",
            install_machine.config.paths.repo_path, package_meta.name
        );
        fs::remove_dir_all(&repo_package_string_path).ok();

        if let Ok(upac_lib) = UpacLib::load() {
            let c_database_path = CSlice::from_str(&install_machine.config.paths.database_path);
            let c_package_name = CSlice::from_str(&package_meta.name);

            let mut c_list = CSliceArray {
                ptr: ptr::null_mut(),
                len: 0,
            };
            let return_code = unsafe { (upac_lib.db_list_packages)(c_database_path, &mut c_list) };
            if return_code == 0 {
                unsafe { (upac_lib.list_free)(&mut c_list) };
                let _ = unsafe { (upac_lib.db_remove_package)(c_database_path, c_package_name) };
            }
        }
    }

    progress_bar.finish_and_clear();

    if install_machine.exhausted() {
        let message = format!(
            "install failed after {} retries: {reason}",
            install_machine.config.step_retries
        );
        install_machine.enter(State::Failed(message.clone()));
        anyhow::bail!("{message}");
    }

    install_machine.retries += 1;
    eprintln!(
        "{} retry {}/{}: {reason}",
        "⚠".yellow().bold(),
        install_machine.retries,
        install_machine.config.step_retries
    );

    state_preparing_package(install_machine)
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
    file: String,
    backend: Option<String>,
    checksum: Option<String>,
) -> Result<()> {
    let package_checksum = checksum.ok_or_else(|| {
        anyhow::anyhow!("--checksum is required. Provide the SHA-256 hash of the package file")
    })?;

    let mut install_machine = InstallMachine::new(config, file, backend, package_checksum);

    state_detecting_backend(&mut install_machine).map_err(|err| {
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
