// ── Imports ─────────────────────────────────────────────────────────────────
use anyhow::Result;

use colored::Colorize;

use crate::config::Config;

use self::states::state_validating;
use crate::upac::{UpacLib, UpacLibGuard};

mod states;

// ── Arguments for command ───────────────────────────────────────────────────────────────────────
#[derive(clap::Args)]
pub struct RemoveArgs {
    pub name: Vec<String>,
}

// ── FSM states ───────────────────────────────────────────────────────────────────────
#[derive(Debug, Clone, PartialEq)]
enum State {
    Validating,
    Uninstalling,
    Done,
    Failed(String),
}

// ── FSM machine ────────────────────────────────────────────────────────────────────────
struct RemoveMachine {
    package_names: Vec<String>,

    config: Config,
    upac_lib: Option<UpacLibGuard>,
    stack: Vec<State>,
}

impl RemoveMachine {
    fn new(config: Config, package_names: Vec<String>) -> Self {
        Self {
            package_names,
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
pub fn run(config: Config, args: RemoveArgs) -> Result<()> {
    let mut remove_machine = RemoveMachine::new(config, args.name);

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
