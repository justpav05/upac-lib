// ── Imports ─────────────────────────────────────────────────────────────────
use anyhow::Result;

use colored::Colorize;

use crate::config::Config;
use crate::ffi::CRepoMode;
use crate::upac::{UpacLib, UpacLibGuard};

use self::states::state_validating;

mod states;

// ── Arguments for command ───────────────────────────────────────────────────────────────────────
#[derive(clap::Args)]
pub struct InitArgs {
    #[arg(long, default_value = "/etc/upac/config.toml")]
    pub config_path: String,
}

// ── FSM states ───────────────────────────────────────────────────────────────────────
#[derive(Debug, Clone, PartialEq)]
enum State {
    Validating,
    Initializing,
    Done,
    Failed(String),
}

// ── FSM machine ───────────────────────────────────────────────────────────────────────
struct InitMachine {
    repo_mode_c: CRepoMode,

    config_path: String,

    config: Config,
    upac_lib: Option<UpacLibGuard>,
    stack: Vec<State>,
}

impl InitMachine {
    fn new(repo_mode_c: CRepoMode, config_path: String, config: Config) -> Self {
        Self {
            repo_mode_c,
            config_path,
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
pub fn run(config: Config, args: InitArgs) -> Result<()> {
    let repo_mode_c = match config.ostree.mode.as_str() {
        "archive" => CRepoMode::Archive,
        "bare" => CRepoMode::Bare,
        "bare-user" => CRepoMode::BareUser,
        _ => anyhow::bail!(
            "unknown mode '{}'. Available: archive, bare, bare-user",
            config.ostree.mode
        ),
    };

    let mut init_machine = InitMachine::new(repo_mode_c, args.config_path, config);

    state_validating(&mut init_machine).map_err(|err| {
        if !matches!(init_machine.stack.last(), Some(State::Failed(_))) {
            init_machine.enter(State::Failed(err.to_string()));
        }
        if init_machine.config.verbose {
            eprintln!(
                "{} failed at state {:?}",
                "✗".red().bold(),
                init_machine.stack.last()
            );
        }
        err
    })
}
