use anyhow::Result;

use colored::Colorize;

use indicatif::{ProgressBar, ProgressStyle};

use std::time::Duration;

use crate::config::Config;
use crate::ffi::{CSlice, CUninstallRequest, UpacLib, UpacLibGuard};

// ── FSM ───────────────────────────────────────────────────────────────────────
#[derive(Debug, Clone, PartialEq)]
enum State {
    Validating,
    Uninstalling,
    Done,
    Failed(String),
}

struct RemoveMachine {
    config: Config,
    package_names: Vec<String>,
    stack: Vec<State>,
}

impl RemoveMachine {
    fn new(config: Config, package_names: Vec<String>) -> Self {
        Self {
            config,
            package_names,
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

    for name in &machine.package_names {
        if name.is_empty() {
            anyhow::bail!("package name cannot be empty");
        }
        println!("{} removing {}", "→".cyan(), name.bold());
    }

    state_uninstalling(machine)
}

fn state_uninstalling(machine: &mut RemoveMachine) -> Result<()> {
    machine.enter(State::Uninstalling);

    let progress_bar = spinner("Removing packages...");

    let upac_lib = UpacLibGuard::load()?;

    let c_names: Vec<CSlice> = machine
        .package_names
        .iter()
        .map(|name| CSlice::from_str(name))
        .collect();

    let c_remove_request = CUninstallRequest {
        package_names: c_names.as_ptr(),
        package_names_len: c_names.len(),
        repo_path: CSlice::from_str(&machine.config.paths.repo_path),
        root_path: CSlice::from_str(&machine.config.paths.root_path),
        db_path: CSlice::from_str(&machine.config.paths.database_path),
        branch: CSlice::from_str(&machine.config.ostree.branch),
        max_retries: machine.config.step_retries,
    };

    let return_code = unsafe { (upac_lib.uninstall)(c_remove_request) };

    progress_bar.finish_and_clear();
    UpacLib::check(return_code, "uninstall")?;

    state_done(machine)
}

fn state_done(machine: &mut RemoveMachine) -> Result<()> {
    machine.enter(State::Done);
    for name in &machine.package_names {
        println!("{} removed {}", "✓".green().bold(), name.bold());
    }
    Ok(())
}

// ── Публичное API ─────────────────────────────────────────────────────────────
pub fn run(config: Config, package_names: Vec<String>) -> Result<()> {
    let mut remove_machine = RemoveMachine::new(config, package_names);

    state_validating(&mut remove_machine).map_err(|err| {
        if !matches!(remove_machine.stack.last(), Some(State::Failed(_))) {
            remove_machine.enter(State::Failed(err.to_string()));
        }
        if remove_machine.config.verbose {
            eprintln!(
                "{} failed at state {:?}",
                "✗".red().bold(),
                remove_machine.stack.last()
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
