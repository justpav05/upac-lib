// ── Imports ─────────────────────────────────────────────────────────────────
use anyhow::Result;
use colored::Colorize;
use indicatif::ProgressBar;

use std::ffi::c_void;
use std::sync::Arc;

use crate::config::Config;

use self::states::state_validating;
use crate::ffi::CSlice;
use crate::upac::UpacLib;

mod states;

// ── Arguments for command ───────────────────────────────────────────────────────────────────────
#[derive(clap::Args)]
pub struct RemoveArgs {
    #[arg(required = true, num_args = 1..)]
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

    upac_lib: Arc<UpacLib>,
    progress_bar: ProgressBar,
    config: Config,
    stack: Vec<State>,
}

impl RemoveMachine {
    fn new(config: Config, package_names: Vec<String>) -> Result<Self> {
        Ok(Self {
            package_names,
            progress_bar: ProgressBar::new_spinner(),
            upac_lib: Arc::new(UpacLib::load()?),
            config,
            stack: Vec::new(),
        })
    }

    fn enter(&mut self, state: State) {
        self.stack.push(state);
    }
}

// ── Public API ─────────────────────────────────────────────────────────────
pub fn run(config: Config, args: RemoveArgs) -> Result<()> {
    let mut remove_machine = RemoveMachine::new(config, args.name)?;

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
pub unsafe extern "C" fn on_remove_progress(event: u8, package_name: CSlice, ctx: *mut c_void) {
    let progress_bar = &*(ctx as *const ProgressBar);

    let name = unsafe { package_name.as_str() };

    match event {
        0 => progress_bar.set_message(format!("Verifying {name}...")),
        1 => progress_bar.set_message("Opening repo...".to_string()),
        2 => progress_bar.set_message(format!("Checking {name} installed...")),
        3 => {}
        4 => progress_bar.set_message(format!("Removing files for {name}...")),
        5 => progress_bar.set_message(format!("Removing database for {name}...")),
        6 => progress_bar.set_message(format!("Committing {name}...")),
        7 => {}
        8 => {}
        9 => {}
        10 => progress_bar.println(format!("{} Done", "✓".green().bold())),
        11 => progress_bar.println(format!("{} Failed", "✗".red().bold())),
        _ => {
            eprintln!("Unknow event: {}", event);
            return;
        }
    }
}
