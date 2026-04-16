// ── Imports ─────────────────────────────────────────────────────────────────
use anyhow::Result;

use colored::Colorize;

use self::states::state_fetching_commits;

use crate::config::Config;
use crate::upac::{UpacLib, UpacLibGuard};

mod states;

// ── Row types ────────────────────────────────────────────────────────────────────────
struct PackageRow {
    name: String,
    version: String,
    author: String,
    license: String,
}

struct CommitRow {
    checksum: String,
    subject: String,
}

// ── Arguments for command ───────────────────────────────────────────────────────────────────────
#[derive(clap::Args)]
pub struct ListArgs {
    #[arg(long)]
    pub commit: bool,
    #[arg(long)]
    pub full: bool,
}

// ── FSM states ────────────────────────────────────────────────────────────────────────
#[derive(Debug, Clone, PartialEq)]
enum State {
    FetchingCommits,
    Printing,
    Done,
    Failed(String),
}

// ── FSM machine ────────────────────────────────────────────────────────────────────────
struct ListMachine {
    full: bool,
    commits_mode: bool,

    commits: Vec<CommitRow>,
    packages: Vec<PackageRow>,

    config: Config,
    upac_lib: Option<UpacLibGuard>,
    stack: Vec<State>,
}

impl ListMachine {
    fn new(config: Config, commits_mode: bool, full: bool) -> Self {
        Self {
            full,

            commits_mode,
            packages: Vec::new(),

            commits: Vec::new(),

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
pub fn run(config: Config, args: ListArgs) -> Result<()> {
    let mut list_machine = ListMachine::new(config, args.commit, args.full);

    state_fetching_commits(&mut list_machine).map_err(|err| {
        if !matches!(list_machine.stack.last(), Some(State::Failed(_))) {
            list_machine.enter(State::Failed(err.to_string()));
        }
        if list_machine.config.verbose {
            eprintln!(
                "{} failed at state {:?}",
                "✗".red().bold(),
                list_machine.stack.last()
            );
        }
        err
    })
}
