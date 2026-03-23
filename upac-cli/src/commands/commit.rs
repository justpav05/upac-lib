use anyhow::Result;

use colored::Colorize;

use indicatif::{ProgressBar, ProgressStyle};

use std::time::Duration;

use crate::config::Config;
use crate::ffi::{CCommitRequest, COstreeOperation, CSlice, UpacLib};

// ── FSM ───────────────────────────────────────────────────────────────────────
#[derive(Debug, Clone, PartialEq)]
enum State {
    Validating,
    Committing,
    Done,
    Failed(String),
}

struct CommitMachine {
    config: Config,
    stack: Vec<State>,
}

impl CommitMachine {
    fn new(config: Config) -> Self {
        Self {
            config,
            stack: Vec::new(),
        }
    }

    fn enter(&mut self, state: State) {
        self.stack.push(state);
    }
}

// ── Состояния ─────────────────────────────────────────────────────────────────
fn state_validating(commit_machine: &mut CommitMachine) -> Result<()> {
    commit_machine.enter(State::Validating);

    if !commit_machine.config.ostree.enabled {
        anyhow::bail!("OStree is disabled in config. Set ostree.enabled = true to use commit");
    }

    state_committing(commit_machine)
}

fn state_committing(commit_machine: &mut CommitMachine) -> Result<()> {
    commit_machine.enter(State::Committing);

    let progress_bar = spinner("Creating OStree snapshot...");

    let upac_lib = UpacLib::load()?;

    let c_commit_request = CCommitRequest {
        repo_path: CSlice::from_str(&commit_machine.config.paths.ostree_path),
        content_path: CSlice::from_str(&commit_machine.config.paths.repo_path),
        branch: CSlice::from_str(&commit_machine.config.ostree.branch),
        operation: COstreeOperation::Manual,
        packages: std::ptr::null(),
        packages_len: 0,
        db_path: CSlice::from_str(&commit_machine.config.paths.database_path),
    };

    let return_code = unsafe { (upac_lib.ostree_commit)(c_commit_request) };

    progress_bar.finish_and_clear();
    UpacLib::check(return_code, "commit")?;

    state_done(commit_machine)
}

fn state_done(commit_machine: &mut CommitMachine) -> Result<()> {
    commit_machine.enter(State::Done);

    println!("{} snapshot created", "✓".green().bold());

    Ok(())
}

// ── Публичное API ─────────────────────────────────────────────────────────────
pub fn run(config: Config) -> Result<()> {
    let mut commit_machine = CommitMachine::new(config);

    state_validating(&mut commit_machine).map_err(|err| {
        if !matches!(commit_machine.stack.last(), Some(State::Failed(_))) {
            commit_machine.enter(State::Failed(err.to_string()));
        }
        if commit_machine.config.verbose {
            eprintln!(
                "{} failed at state {:?}",
                "✗".red().bold(),
                commit_machine.stack.last()
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
