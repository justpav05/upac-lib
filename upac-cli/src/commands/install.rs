use anyhow::Result;

use colored::Colorize;

use indicatif::{ProgressBar, ProgressStyle};

use std::time::Duration;

use crate::backends::{Backend, BackendKind, PackageMeta};

use crate::config::Config;

use crate::ffi::{CInstallRequest, CSlice, CSliceArray, UpacLib};

const MAX_RETRIES: u8 = 10;

// ── FSM ───────────────────────────────────────────────────────────────────────
#[derive(Debug, Clone, PartialEq)]
enum State {
    DetectingBackend,
    PreparingPackage,
    Installing,
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
    meta: Option<PackageMeta>,

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
            meta: None,
            stack: Vec::new(),
        }
    }

    fn enter(&mut self, state: State) {
        self.stack.push(state);
    }

    fn exhausted(&self) -> bool {
        self.retries >= MAX_RETRIES
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
fn state_detecting_backend(machine: &mut InstallMachine) -> Result<()> {
    machine.enter(State::DetectingBackend);

    let kind = if let Some(flag) = &machine.backend.clone() {
        BackendKind::from_flag(flag)?
    } else {
        BackendKind::detect(&machine.file).ok_or_else(|| {
            anyhow::anyhow!(
                "cannot detect backend for '{}'. Use --backend to specify one",
                machine.file
            )
        })?
    };

    println!("{} backend: {:?}", "→".cyan(), kind);
    machine.kind = Some(kind);

    state_preparing_package(machine)
}

fn state_preparing_package(machine: &mut InstallMachine) -> Result<()> {
    machine.enter(State::PreparingPackage);

    let pb = spinner("Verifying and extracting package...");

    let tmp = format!("/tmp/upac_install_{}", std::process::id());
    std::fs::remove_dir_all(&tmp).ok();
    std::fs::create_dir_all(&tmp)?;
    machine.tmp_dir = Some(tmp.clone());

    let backend = Backend::load(machine.kind.as_ref().unwrap())?;

    let meta = backend
        .prepare(&machine.file, &tmp, &machine.checksum)
        .map_err(|err| {
            pb.finish_and_clear();
            err
        })?;

    pb.finish_and_clear();
    println!(
        "{} {} {}",
        "✓".green().bold(),
        meta.name.bold(),
        meta.version.dimmed()
    );

    machine.meta = Some(meta);

    state_installing(machine)
}

fn state_installing(machine: &mut InstallMachine) -> Result<()> {
    machine.enter(State::Installing);

    let pb = spinner(&format!(
        "Installing{}...",
        if machine.retries > 0 {
            format!(" (retry {}/{})", machine.retries, MAX_RETRIES)
        } else {
            String::new()
        }
    ));

    let lib = UpacLib::load()?;

    let meta = machine.meta.as_ref().unwrap();
    let tmp_dir = machine.tmp_dir.as_ref().unwrap();
    let c_meta = meta.as_c();

    let request = CInstallRequest {
        meta: c_meta,
        root_path: CSlice::from_str(&machine.config.paths.root_path),
        repo_path: CSlice::from_str(&machine.config.paths.repo_path),
        package_path: CSlice::from_str(tmp_dir),
        db_path: CSlice::from_str(&machine.config.paths.db_path),
        max_retries: 3,
    };

    let code = unsafe { (lib.install)(request) };

    pb.finish_and_clear();

    if let Err(err) = UpacLib::check(code, "install") {
        return state_rolling_back(machine, err.to_string());
    }

    state_done(machine)
}

fn state_rolling_back(machine: &mut InstallMachine, reason: String) -> Result<()> {
    machine.enter(State::RollingBack);

    let pb = spinner("Rolling back...");

    if let Some(meta) = machine.meta.as_ref() {
        let repo_pkg = format!("{}/{}", machine.config.paths.repo_path, meta.name);
        std::fs::remove_dir_all(&repo_pkg).ok();

        if let Ok(lib) = UpacLib::load() {
            let db_path = CSlice::from_str(&machine.config.paths.db_path);
            let name = CSlice::from_str(&meta.name);

            let mut list = CSliceArray {
                ptr: std::ptr::null_mut(),
                len: 0,
            };
            let list_code = unsafe { (lib.db_list_packages)(db_path, &mut list) };
            if list_code == 0 {
                unsafe { (lib.list_free)(&mut list) };
                let _ = unsafe { (lib.db_remove_package)(db_path, name) };
            }
        }
    }

    pb.finish_and_clear();

    if machine.exhausted() {
        let msg = format!("install failed after {} retries: {reason}", MAX_RETRIES);
        machine.enter(State::Failed(msg.clone()));
        anyhow::bail!("{msg}");
    }

    machine.retries += 1;
    eprintln!(
        "{} retry {}/{}: {reason}",
        "⚠".yellow().bold(),
        machine.retries,
        MAX_RETRIES
    );

    state_preparing_package(machine)
}

fn state_done(machine: &mut InstallMachine) -> Result<()> {
    machine.enter(State::Done);

    let meta = machine.meta.as_ref().unwrap();
    println!(
        "{} installed {} {}",
        "✓".green().bold(),
        meta.name.bold(),
        meta.version.dimmed()
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
    let checksum = checksum.ok_or_else(|| {
        anyhow::anyhow!("--checksum is required. Provide the SHA-256 hash of the package file")
    })?;

    let mut machine = InstallMachine::new(config, file, backend, checksum);

    state_detecting_backend(&mut machine).map_err(|err| {
        if !matches!(machine.stack.last(), Some(State::Failed(_))) {
            machine.enter(State::Failed(err.to_string()));
        }
        eprintln!(
            "{} failed at state {:?}",
            "✗".red().bold(),
            machine.stack.last()
        );
        err
    })
}

// ── Хелперы ───────────────────────────────────────────────────────────────────

fn spinner(msg: &str) -> ProgressBar {
    let pb = ProgressBar::new_spinner();
    pb.set_style(
        ProgressStyle::default_spinner()
            .tick_strings(&["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"])
            .template("{spinner:.cyan} {msg}")
            .unwrap(),
    );
    pb.set_message(msg.to_owned());
    pb.enable_steady_tick(Duration::from_millis(80));
    pb
}
