use anyhow::Result;

use colored::Colorize;

use indicatif::{ProgressBar, ProgressStyle};

use std::path::Path;
use std::time::Duration;

use crate::config::Config;
use crate::ffi::{CRepoMode, CSlice, CSystemPaths, UpacLib};

// ── FSM ───────────────────────────────────────────────────────────────────────
#[derive(Debug, Clone, PartialEq)]
enum State {
    Validating,
    Initializing,
    Done,
    Failed(String),
}

struct InitMachine {
    c_repo_mode: CRepoMode,
    config: Config,
    stack: Vec<State>,
}

impl InitMachine {
    fn new(c_repo_mode: CRepoMode, config: Config) -> Self {
        Self {
            c_repo_mode,
            config,
            stack: Vec::new(),
        }
    }

    fn enter(&mut self, state: State) {
        self.stack.push(state);
    }
}

// ── Состояния ─────────────────────────────────────────────────────────────────
fn state_validating(init_machine: &mut InitMachine) -> Result<()> {
    init_machine.enter(State::Validating);

    let config_path = Path::new(&init_machine.config.paths.config_path);

    if !config_path.exists() {
        anyhow::bail!(
            "config file not found: {}\n\
             Create it before running init. Example:\n\
             \n\
             verbose = false\n\
             \n\
             [paths]\n\
             db_path     = \"/var/db/upac\"\n\
             repo_path   = \"/var/repo\"\n\
             root_path   = \"/\"\n\
             ostree_path = \"/var/ostree\"\n\
             \n\
             [ostree]\n\
             enabled = false\n\
             branch  = \"packages\"",
            init_machine.config.paths.config_path
        );
    }

    state_initializing(init_machine)
}

fn state_initializing(init_machine: &mut InitMachine) -> Result<()> {
    init_machine.enter(State::Initializing);

    let progress_bar = spinner("Initializing system directories...");

    let upac_lib = UpacLib::load()?;

    let c_system_paths = CSystemPaths {
        repo_path: CSlice::from_str(&init_machine.config.paths.ostree_path),
        root_path: CSlice::from_str(&init_machine.config.paths.root_path),
    };

    let return_code = unsafe { (upac_lib.init)(c_system_paths, init_machine.c_repo_mode) };

    progress_bar.finish_and_clear();
    UpacLib::check(return_code, "init")?;

    state_done(init_machine)
}

fn state_done(init_machine: &mut InitMachine) -> Result<()> {
    init_machine.enter(State::Done);

    println!("{} system initialized", "✓".green().bold());
    println!(
        "  {}",
        "Run 'upac list' to verify the installation.".dimmed()
    );

    Ok(())
}

// ── Публичное API ─────────────────────────────────────────────────────────────
pub fn run(config: Config, repo_mode: String) -> Result<()> {
    let c_repo_mode = match repo_mode.as_str() {
        "archive" => CRepoMode::Archive,
        "bare" => CRepoMode::Bare,
        "bare-user" => CRepoMode::BareUser,
        _ => anyhow::bail!("unknown mode '{repo_mode}'. Available: archive, bare, bare-user"),
    };

    let mut init_machine = InitMachine::new(c_repo_mode, config);

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

// ── Хелперы ───────────────────────────────────────────────────────────────────
fn spinner(message: &str) -> ProgressBar {
    let progress_bar = ProgressBar::new_spinner();
    progress_bar.set_style(
        ProgressStyle::default_spinner()
            .tick_strings(&["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"])
            .template("{spinner:.cyan} {msg}")
            .unwrap(),
    );
    progress_bar.set_message(message.to_owned());
    progress_bar.enable_steady_tick(Duration::from_millis(80));
    progress_bar
}
