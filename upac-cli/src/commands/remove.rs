use anyhow::Result;

use colored::Colorize;

use indicatif::{ProgressBar, ProgressStyle};

use std::mem::MaybeUninit;
use std::time::Duration;

use crate::backends::PackageMeta;
use crate::config::Config;
use crate::ffi::{CPackageMeta, CSlice, CUninstallRequest, UpacLib};

// ── FSM ───────────────────────────────────────────────────────────────────────
#[derive(Debug, Clone, PartialEq)]
enum State {
    Validating,
    Uninstalling,
    Committing,
    Done,
    Failed(String),
}

struct RemoveMachine {
    config: Config,
    package_name: String,
    package_meta: Option<PackageMeta>,
    stack: Vec<State>,
}

impl RemoveMachine {
    fn new(config: Config, package_name: String) -> Self {
        Self {
            config,
            package_name,
            package_meta: None,
            stack: Vec::new(),
        }
    }

    fn enter(&mut self, state: State) {
        self.stack.push(state);
    }
}

// ── Состояния ─────────────────────────────────────────────────────────────────
fn state_validating(machine: &mut RemoveMachine) -> Result<()> {
    machine.enter(State::Validating);

    let upac_lib = UpacLib::load()?;
    let database_path = CSlice::from_str(&machine.config.paths.database_path);
    let name = CSlice::from_str(&machine.package_name);

    let mut c_test_package_meta = MaybeUninit::uninit();
    let code =
        unsafe { (upac_lib.db_get_meta)(database_path, name, c_test_package_meta.as_mut_ptr()) };

    if code != 0 {
        anyhow::bail!("package '{}' is not installed", machine.package_name);
    }

    let c_package_meta = unsafe { c_test_package_meta.assume_init() };
    let package_meta = unsafe {
        PackageMeta {
            name: c_package_meta.name.as_str().to_owned(),
            version: c_package_meta.version.as_str().to_owned(),
            author: c_package_meta.author.as_str().to_owned(),
            description: c_package_meta.description.as_str().to_owned(),
            license: c_package_meta.license.as_str().to_owned(),
            url: c_package_meta.url.as_str().to_owned(),
            installed_at: c_package_meta.installed_at,
            checksum: c_package_meta.checksum.as_str().to_owned(),
        }
    };

    let mut package_meta_owned = c_package_meta;
    unsafe { (upac_lib.meta_free)(&mut package_meta_owned) };

    machine.package_meta = Some(package_meta);

    println!("{} removing {}", "→".cyan(), machine.package_name.bold());

    state_uninstalling(machine)
}

fn state_uninstalling(machine: &mut RemoveMachine) -> Result<()> {
    machine.enter(State::Uninstalling);

    let progress_bar = spinner("Removing package...");

    let upac_lib = UpacLib::load()?;

    let request = CUninstallRequest {
        package_name: CSlice::from_str(&machine.package_name),
        root_path: CSlice::from_str(&machine.config.paths.root_path),
        repo_path: CSlice::from_str(&machine.config.paths.repo_path),
        db_path: CSlice::from_str(&machine.config.paths.database_path),
        max_retries: 3,
    };

    let code = unsafe { (upac_lib.uninstall)(request) };

    progress_bar.finish_and_clear();
    UpacLib::check(code, "uninstall")?;

    if machine.config.ostree.enabled {
        return state_committing(machine);
    }

    state_done(machine)
}

fn state_committing(machine: &mut RemoveMachine) -> Result<()> {
    machine.enter(State::Committing);

    let progress_bar = spinner("Creating OStree snapshot...");

    let upac_lib = UpacLib::load()?;

    let request = crate::ffi::CCommitRequest {
        repo_path: CSlice::from_str(&machine.config.paths.ostree_path),
        content_path: CSlice::from_str(&machine.config.paths.repo_path),
        branch: CSlice::from_str(&machine.config.ostree.branch),
        operation: crate::ffi::COstreeOperation::Remove,
        packages: std::ptr::null(),
        packages_len: 0,
        db_path: CSlice::from_str(&machine.config.paths.database_path),
    };

    let code = unsafe { (upac_lib.ostree_commit)(request) };

    progress_bar.finish_and_clear();

    if let Err(err) = UpacLib::check(code, "ostree commit") {
        eprintln!("{} ostree snapshot failed: {err}", "⚠".yellow().bold());
        return Ok(());
    }

    println!("{} snapshot created", "✓".green().bold());
    state_done(machine)
}

fn state_done(machine: &mut RemoveMachine) -> Result<()> {
    machine.enter(State::Done);
    println!(
        "{} removed {}",
        "✓".green().bold(),
        machine.package_name.bold()
    );
    Ok(())
}

// ── Публичное API ─────────────────────────────────────────────────────────────
pub fn run(config: Config, package_name: String) -> Result<()> {
    let mut machine = RemoveMachine::new(config, package_name);

    state_validating(&mut machine).map_err(|err| {
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
