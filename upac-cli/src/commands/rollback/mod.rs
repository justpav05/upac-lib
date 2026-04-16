// ── Imports ─────────────────────────────────────────────────────────────────
use anyhow::Result;

use colored::Colorize;

use crate::config::Config;
use crate::upac::{UpacLib, UpacLibGuard};

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

    config: Config,
    upac_lib: Option<UpacLibGuard>,
    stack: Vec<State>,
}

impl RollbackMachine {
    fn new(config: Config, commit_hash: String) -> Self {
        Self {
            commit_hash,
            config,
            upac_lib: None,
            stack: Vec::new(),
        }
    }

    fn enter(&mut self, state: State) {
        self.stack.push(state);
    }
}

// ── Public API ─────────────────────────────────────────────────────────────
pub fn run(config: Config, args: RollbackArgs) -> Result<()> {
    let mut rolling_machine = RollbackMachine::new(config, args.commit);

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
