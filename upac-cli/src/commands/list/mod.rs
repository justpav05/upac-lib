// ── Imports ─────────────────────────────────────────────────────────────────
use anyhow::Result;

use colored::Colorize;

use std::ffi::c_void;
use std::sync::Arc;

use self::states::state_fetching_mode;

use crate::config::Config;
use crate::upac::UpacLib;

mod states;

// ── Row types ────────────────────────────────────────────────────────────────────────
struct PackageRow {
    name: String,
    version: String,
    size: u32,
    architecture: String,
    author: String,
    license: String,
    url: String,
    packager: String,
}

struct CommitRow {
    checksum: String,
    subject: String,
}

pub struct HandleGuard {
    pub handle: *mut c_void,
    free_fn: unsafe extern "C" fn(*mut c_void),
}

impl HandleGuard {
    pub fn new(handle: *mut c_void, free_fn: unsafe extern "C" fn(*mut c_void)) -> Self {
        Self { handle, free_fn }
    }
}

impl Drop for HandleGuard {
    fn drop(&mut self) {
        if !self.handle.is_null() {
            unsafe { (self.free_fn)(self.handle) };
            self.handle = std::ptr::null_mut();
        }
    }
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
    FetchingMode,
    GetPackages,
    GetCommits,
    PrintCommits,
    PrintPackages,

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
    upac_lib: Arc<UpacLib>,
    stack: Vec<State>,
}

impl ListMachine {
    fn new(config: Config, commits_mode: bool, full: bool) -> Result<Self> {
        Ok(Self {
            full,

            commits_mode,
            packages: Vec::new(),

            commits: Vec::new(),

            config,
            upac_lib: Arc::new(UpacLib::load()?),
            stack: Vec::new(),
        })
    }

    fn enter(&mut self, state: State) {
        self.stack.push(state);
    }
}

// ── Public API ─────────────────────────────────────────────────────────────
pub fn run(config: Config, args: ListArgs) -> Result<()> {
    let mut list_machine = ListMachine::new(config, args.commit, args.full)?;

    state_fetching_mode(&mut list_machine).map_err(|err| {
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

pub fn format_size(bytes: u32) -> String {
    const KB: u32 = 1024;
    const MB: u32 = 1024 * KB;
    const GB: u32 = 1024 * MB;

    if bytes >= GB {
        format!("{:.1} GiB", bytes as f64 / GB as f64)
    } else if bytes >= MB {
        format!("{:.1} MiB", bytes as f64 / MB as f64)
    } else if bytes >= KB {
        format!("{:.1} KiB", bytes as f64 / KB as f64)
    } else {
        format!("{} B", bytes)
    }
}
