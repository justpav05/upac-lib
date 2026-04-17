// ── Imports ─────────────────────────────────────────────────────────────────
use anyhow::Result;

use colored::Colorize;

use indicatif::ProgressBar;

use std::ffi::c_void;

use crate::config::Config;

use self::states::state_validating;
use crate::ffi::CSlice;
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

#[repr(u8)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum InstallProgressEvent {
    Verifying = 0,
    OpeningRepo = 1,
    CheckingInstalled = 2,
    RemovingFromDatabase = 3,
    ProcessingFiles = 4,
    Committing = 5,
    Ready = 6,
    Failed = 7,
}

// ── FSM machine ────────────────────────────────────────────────────────────────────────
struct RemoveMachine {
    package_names: Vec<String>,

    progress_bar: Option<ProgressBar>,

    upac_lib: Option<UpacLibGuard>,
    config: Config,
    stack: Vec<State>,
}

impl RemoveMachine {
    fn new(config: Config, package_names: Vec<String>) -> Self {
        Self {
            package_names,
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

// ── Helpers ───────────────────────────────────────────────────────────────────
pub unsafe extern "C" fn on_remove_progress(event_raw: u8, package_name: CSlice, ctx: *mut c_void) {
    let progress_bar = &*(ctx as *const ProgressBar);
    let event = unsafe { std::mem::transmute::<u8, InstallProgressEvent>(event_raw) };

    let name = unsafe { package_name.as_str() };

    match event {
        InstallProgressEvent::Verifying => progress_bar.set_message(format!("verifying {name}...")),
        InstallProgressEvent::OpeningRepo => {
            progress_bar.set_message("opening repo...".to_string())
        }
        InstallProgressEvent::CheckingInstalled => {
            progress_bar.set_message(format!("checking if {name} is installed..."))
        }
        InstallProgressEvent::RemovingFromDatabase => {
            progress_bar.set_message(format!("removing database for {name}..."))
        }
        InstallProgressEvent::ProcessingFiles => {
            progress_bar.set_message(format!("processing files for {name}..."))
        }
        InstallProgressEvent::Committing => {
            progress_bar.set_message(format!("committing {name}..."))
        }
        InstallProgressEvent::Ready => {
            progress_bar.println(format!("{} {name}done", "✓".green().bold()))
        }
        InstallProgressEvent::Failed => {
            progress_bar.println(format!("{} {name}failed", "✗".red().bold()))
        }
    }
}
