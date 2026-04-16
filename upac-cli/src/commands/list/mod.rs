// ── Imports ─────────────────────────────────────────────────────────────────
use anyhow::Result;

use colored::Colorize;

use self::states::state_fetching_commits;

use crate::config::Config;

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
    stack: Vec<State>,
}

impl ListMachine {
    fn new(config: Config, commits_mode: bool, full: bool) -> Self {
        Self {
            config,
            full,

            commits_mode,
            packages: Vec::new(),

            commits: Vec::new(),

            stack: Vec::new(),
        }
    }

    fn enter(&mut self, state: State) {
        self.stack.push(state);
    }
}

// ── Public API ─────────────────────────────────────────────────────────────
pub fn run(config: Config, args: ListArgs) -> Result<()> {
    let mut machine = ListMachine::new(config, args.commit, args.full);

    state_fetching_commits(&mut machine).map_err(|err| {
        if !matches!(machine.stack.last(), Some(State::Failed(_))) {
            machine.enter(State::Failed(err.to_string()));
        }
        if machine.config.verbose {
            eprintln!(
                "{} failed at state {:?}",
                "✗".red().bold(),
                machine.stack.last()
            );
        }
        err
    })
}
