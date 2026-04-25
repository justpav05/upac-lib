// ── Imports ─────────────────────────────────────────────────────────────────
use anyhow::Result;
use colored::Colorize;
use indicatif::ProgressBar;

use std::sync::Arc;

use crate::config::Config;
use crate::types::BackendKind;
use crate::upac::UpacLib;

use self::states::state_validating;

mod states;

// ── Arguments for command ───────────────────────────────────────────────────────────────────────
#[derive(clap::Args)]
pub struct RollbackArgs {
    pub commit: String,
}

// ── FSM states ───────────────────────────────────────────────────────────────────────
#[derive(Debug, Clone, PartialEq)]
enum State {
    Validating,
    RollingBack,
    Done,
    Failed(String),
}

// ── FSM machine ───────────────────────────────────────────────────────────────────────
struct RollbackMachine {
    commit_hash: String,

    upac_lib: Arc<UpacLib>,
    progress_bar: ProgressBar,
    config: Config,
    stack: Vec<State>,
}

impl RollbackMachine {
    fn new(config: Config, commit_hash: String) -> Result<Self> {
        Ok(Self {
            commit_hash,
            progress_bar: ProgressBar::new_spinner(),
            upac_lib: Arc::new(UpacLib::load(&BackendKind::UpacLib)?),
            config,
            stack: Vec::new(),
        })
    }

    fn enter(&mut self, state: State) {
        self.stack.push(state);
    }
}

// ── Public API ─────────────────────────────────────────────────────────────
pub fn run(config: Config, args: RollbackArgs) -> Result<()> {
    let mut rolling_machine = RollbackMachine::new(config, args.commit)?;

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
