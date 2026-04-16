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
pub unsafe extern "C" fn on_install_progress(event: u8, package_name: CSlice, ctx: *mut c_void) {
    let pb = &*(ctx as *const ProgressBar);
    let name = unsafe { package_name.as_str() };

    match event {
        0 => pb.set_message(format!("verifying {name}...")),
        1 => pb.set_message("opening repo...".to_string()),
        2 => pb.set_message(format!("checking if {name} is installed...")),
        3 => pb.set_message(format!("writing database for {name}...")),
        4 => pb.set_message(format!("processing files for {name}...")),
        5 => pb.set_message(format!("committing {name}...")),
        6 => pb.println(format!("{} {name} ready", "✓".green().bold())),
        7 => pb.println(format!("{} {name} failed", "✗".red().bold())),
        _ => {}
    }
}
