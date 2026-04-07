use anyhow::Result;

use colored::Colorize;

use indicatif::{ProgressBar, ProgressStyle};

use std::time::Duration;

use crate::config::Config;
use crate::ffi::{CSlice, CUninstallRequest, UpacLib};

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
    package_name: String,
    stack: Vec<State>,
}

impl RemoveMachine {
    fn new(config: Config, package_name: String) -> Self {
        Self {
            config,
            package_name,
            stack: Vec::new(),
        }
    }

    fn enter(&mut self, state: State) {
        self.stack.push(state);
    }
}

// ── Состояния ─────────────────────────────────────────────────────────────────
fn state_validating(remove_machine: &mut RemoveMachine) -> Result<()> {
    remove_machine.enter(State::Validating);

    if remove_machine.package_name.is_empty() {
        anyhow::bail!("package name cannot be empty");
    }

    println!(
        "{} removing {}",
        "→".cyan(),
        remove_machine.package_name.bold()
    );

    state_uninstalling(remove_machine)
}

fn state_uninstalling(remove_machine: &mut RemoveMachine) -> Result<()> {
    remove_machine.enter(State::Uninstalling);

    let progress_bar = spinner("Removing package...");

    let upac_lib = UpacLib::load()?;

    let branch = if remove_machine.config.ostree.enabled {
        &remove_machine.config.ostree.branch
    } else {
        ""
    };

    let c_remove_request = CUninstallRequest {
        package_name: CSlice::from_str(&remove_machine.package_name),
        repo_path: CSlice::from_str(&remove_machine.config.paths.repo_path),
        root_path: CSlice::from_str(&remove_machine.config.paths.root_path),
        db_path: CSlice::from_str(&remove_machine.config.paths.database_path),
        branch: CSlice::from_str(branch),
        max_retries: remove_machine.config.step_retries,
    };

    let return_code = unsafe { (upac_lib.uninstall)(c_remove_request) };

    progress_bar.finish_and_clear();
    UpacLib::check(return_code, "uninstall")?;

    state_done(remove_machine)
}

fn state_done(remove_machine: &mut RemoveMachine) -> Result<()> {
    remove_machine.enter(State::Done);
    println!(
        "{} removed {}",
        "✓".green().bold(),
        remove_machine.package_name.bold()
    );
    Ok(())
}

// ── Публичное API ─────────────────────────────────────────────────────────────
pub fn run(config: Config, package_name: String) -> Result<()> {
    let mut remove_machine = RemoveMachine::new(config, package_name);

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
