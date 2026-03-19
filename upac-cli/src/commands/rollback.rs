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
    commit: String,
    stack: Vec<State>,
}

impl RollbackMachine {
    fn new(config: Config, commit: String) -> Self {
        Self {
            config,
            commit,
            stack: Vec::new(),
        }
    }

    fn enter(&mut self, state: State) {
        self.stack.push(state);
    }
}

// ── Состояния ─────────────────────────────────────────────────────────────────
fn state_validating(machine: &mut RollbackMachine) -> Result<()> {
    machine.enter(State::Validating);

    if !machine.config.ostree.enabled {
        anyhow::bail!("OStree is disabled in config. Set ostree.enabled = true to use rollback");
    }

    if machine.commit.len() != 64 || !machine.commit.chars().all(|c| c.is_ascii_hexdigit()) {
        anyhow::bail!(
            "invalid commit hash '{}'. Expected 64 hex characters",
            machine.commit
        );
    }

    println!(
        "{} rolling back to {}",
        "→".cyan(),
        &machine.commit[..12].dimmed()
    );

    state_rolling_back(machine)
}

fn state_rolling_back(machine: &mut RollbackMachine) -> Result<()> {
    machine.enter(State::RollingBack);

    let pb = spinner("Rolling back...");

    let lib = UpacLib::load()?;

    let repo_path = CSlice::from_str(&machine.config.paths.ostree_path);
    let content_path = CSlice::from_str(&machine.config.paths.repo_path);
    let branch = CSlice::from_str(&machine.config.ostree.branch);

    let commit = CSlice::from_str(&machine.commit);

    let code = unsafe { (lib.ostree_rollback)(repo_path, content_path, commit) };

    pb.finish_and_clear();

    UpacLib::check(code, "rollback")?;

    println!(
        "{} {}",
        "⚠".yellow().bold(),
        "Hardlinks need to be refreshed. Run: upac refresh".dimmed()
    );

    // Так же нужно обновить БД чтобы она отражала состояние после отката
    // TODO: upac refresh команда синхронизирует БД с файловой системой

    state_done(machine)
}

fn state_done(machine: &mut RollbackMachine) -> Result<()> {
    machine.enter(State::Done);
    println!(
        "{} rolled back to {}",
        "✓".green().bold(),
        &machine.commit[..12].bold()
    );
    Ok(())
}

// ── Публичное API ─────────────────────────────────────────────────────────────
pub fn run(config: Config, commit: String) -> Result<()> {
    let mut machine = RollbackMachine::new(config, commit);

    state_validating(&mut machine).map_err(|err| {
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
