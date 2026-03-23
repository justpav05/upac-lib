use anyhow::Result;

use colored::Colorize;

use indicatif::{ProgressBar, ProgressStyle};

use std::time::Duration;

use crate::config::Config;

use crate::ffi::{CSlice, UpacLib};

// ── FSM ───────────────────────────────────────────────────────────────────────
#[derive(Debug, Clone, PartialEq)]
enum State {
    Validating,
    RollingBack,
    Done,
    Failed(String),
}

struct RollbackMachine {
    config: Config,
    commit_hash: String,
    stack: Vec<State>,
}

impl RollbackMachine {
    fn new(config: Config, commit_hash: String) -> Self {
        Self {
            config,
            commit_hash,
            stack: Vec::new(),
        }
    }

    fn enter(&mut self, state: State) {
        self.stack.push(state);
    }
}

// ── Состояния ─────────────────────────────────────────────────────────────────
fn state_validating(rolling_machine: &mut RollbackMachine) -> Result<()> {
    rolling_machine.enter(State::Validating);

    if !rolling_machine.config.ostree.enabled {
        anyhow::bail!("OStree is disabled in config. Set ostree.enabled = true to use rollback");
    }

    if rolling_machine.commit_hash.len() != 64
        || !rolling_machine
            .commit_hash
            .chars()
            .all(|char| char.is_ascii_hexdigit())
    {
        anyhow::bail!(
            "invalid commit hash '{}'. Expected 64 hex characters",
            rolling_machine.commit_hash
        );
    }

    println!(
        "{} rolling back to {}",
        "→".cyan(),
        &rolling_machine.commit_hash[..12].dimmed()
    );

    state_rolling_back(rolling_machine)
}

fn state_rolling_back(rolling_machine: &mut RollbackMachine) -> Result<()> {
    rolling_machine.enter(State::RollingBack);

    let progress_bar = spinner("Rolling back...");

    let upac_lib = UpacLib::load()?;

    let result_code = unsafe {
        (upac_lib.ostree_rollback)(
            CSlice::from_str(&rolling_machine.config.paths.ostree_path),
            CSlice::from_str(&rolling_machine.config.paths.repo_path),
            CSlice::from_str(&rolling_machine.config.ostree.branch),
            CSlice::from_str(&rolling_machine.commit_hash),
        )
    };

    progress_bar.finish_and_clear();
    UpacLib::check(result_code, "rollback")?;

    let progress_bar = spinner("Refreshing links and database...");

    let refresh_code = unsafe {
        (upac_lib.refresh)(
            CSlice::from_str(&rolling_machine.config.paths.ostree_path),
            CSlice::from_str(&rolling_machine.config.paths.repo_path),
            CSlice::from_str(&rolling_machine.config.paths.root_path),
            CSlice::from_str(&rolling_machine.config.ostree.branch),
            CSlice::from_str(&rolling_machine.config.paths.database_path),
        )
    };

    progress_bar.finish_and_clear();
    UpacLib::check(refresh_code, "refresh")?;

    state_done(rolling_machine)
}

fn state_done(machine: &mut RollbackMachine) -> Result<()> {
    machine.enter(State::Done);
    println!(
        "{} rolled back to {}",
        "✓".green().bold(),
        &machine.commit_hash[..12].bold()
    );
    Ok(())
}

// ── Публичное API ─────────────────────────────────────────────────────────────
pub fn run(config: Config, commit_hash: String) -> Result<()> {
    let mut rolling_machine = RollbackMachine::new(config, commit_hash);

    state_validating(&mut rolling_machine).map_err(|err| {
        if !matches!(rolling_machine.stack.last(), Some(State::Failed(_))) {
            rolling_machine.enter(State::Failed(err.to_string()));
        }

        if rolling_machine.config.verbose {
            eprintln!(
                "{} failed at state {:?}",
                "✗".red().bold(),
                rolling_machine.stack.last()
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
