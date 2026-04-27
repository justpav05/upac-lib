// ── Imports ─────────────────────────────────────────────────────────────────
use anyhow::Result;
use colored::Colorize;
use indicatif::ProgressBar;

use clap::Args;

use std::sync::Arc;

use self::states::state_validating;

use crate::config::Config;
use crate::types::BackendKind;
use crate::upac::UpacLib;

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

    FetchingFilesDiff,
    FetchingPackagesDiff,

    PrintingFilesDiff,
    PrintingPackagesDiff,

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
    from_commit: Option<String>,
    to_commit: Option<String>,

    package_rows: Vec<PackageDiffRow>,
    file_rows: Vec<FileDiffRow>,

    files_mode: bool,

    upac_lib: Arc<UpacLib>,
    progress_bar: ProgressBar,
    config: Config,
    stack: Vec<State>,
}

impl DiffMachine {
    fn new(
        config: Config,
        from_commit: Option<String>,
        to_commit: Option<String>,
        files_mode: bool,
    ) -> Result<Self> {
        Ok(Self {
            from_commit,
            to_commit,
            package_rows: Vec::new(),
            file_rows: Vec::new(),
            files_mode,
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
pub fn run(config: Config, args: DiffArgs) -> Result<()> {
    let mut diff_machine = DiffMachine::new(config, args.from, args.to, args.files)?;

    state_validating(&mut diff_machine).map_err(|err| {
        let last_state = diff_machine.stack.last().cloned();
        if !matches!(last_state, Some(State::Failed(_))) {
            diff_machine.enter(State::Failed(err.to_string()));
            unsafe { (diff_machine.upac_lib.as_ref().deinit)() };
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
