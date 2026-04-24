// ── Imports ─────────────────────────────────────────────────────────────────
use anyhow::Result;

use colored::Colorize;

use indicatif::ProgressBar;

use clap::Args;

use self::states::state_validating;

use crate::config::Config;
use crate::upac::{UpacLib, UpacLibGuard};

mod states;

// ── Arguments for command ───────────────────────────────────────────────────────────────────────
#[derive(Args)]
pub struct DiffArgs {
    pub from: Option<String>,
    pub to: Option<String>,
    #[arg(long)]
    pub files: bool,
}

// ── FSM States ───────────────────────────────────────────────────────────────────────
#[derive(Debug, Clone, PartialEq)]
enum State {
    Validating,
    FetchingDiff,
    Printing,

    Done,
    Failed(String),
}

// ── Diff kinds ───────────────────────────────────────────────────────────────────────
#[derive(Debug, Clone, PartialEq)]
enum PkgDiffKind {
    Added,
    Removed,
    Updated,
}

#[derive(Debug, Clone, PartialEq)]
enum FileDiffKind {
    Added,
    Removed,
    Modified,
}

// ── Diff rows ───────────────────────────────────────────────────────────────────────
struct PackageDiffRow {
    name: String,
    kind: PkgDiffKind,
}

struct FileDiffRow {
    path: String,
    kind: FileDiffKind,
    package_name: String,
}

// ── DiffFSM machine ───────────────────────────────────────────────────────────────────────
struct DiffMachine {
    from: Option<String>,
    to: Option<String>,

    resolved_from: String,
    resolved_to: String,

    package_rows: Vec<PackageDiffRow>,
    file_rows: Vec<FileDiffRow>,

    files_mode: bool,

    progress_bar: Option<ProgressBar>,

    upac_lib: Option<UpacLibGuard>,
    config: Config,
    stack: Vec<State>,
}

impl DiffMachine {
    fn new(config: Config, from: Option<String>, to: Option<String>, files_mode: bool) -> Self {
        Self {
            from,
            to,
            resolved_from: String::new(),
            resolved_to: String::new(),
            package_rows: Vec::new(),
            file_rows: Vec::new(),
            files_mode,
            progress_bar: None,
            upac_lib: None,
            config,
            stack: Vec::new(),
        }
    }

    fn enter(&mut self, state: State) {
        self.stack.push(state);
    }
}

// ── Public API ─────────────────────────────────────────────────────────────
pub fn run(config: Config, args: DiffArgs) -> Result<()> {
    let mut diff_machine = DiffMachine::new(config, args.from, args.to, args.files);

    state_validating(&mut diff_machine).map_err(|err| {
        let last_state = diff_machine.stack.last().cloned();
        if !matches!(last_state, Some(State::Failed(_))) {
            diff_machine.enter(State::Failed(err.to_string()));
        }
        if diff_machine.config.verbose {
            eprintln!(
                "{} failed at state {:?}",
                "✗".red().bold(),
                diff_machine.stack.last()
            );
        }
        err
    })
}
