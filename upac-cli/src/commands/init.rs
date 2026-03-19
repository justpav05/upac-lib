use anyhow::Result;

use colored::Colorize;

use indicatif::{ProgressBar, ProgressStyle};

use std::time::Duration;

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
    mode: CRepoMode,
    stack: Vec<State>,
}

impl InitMachine {
    fn new(mode: CRepoMode) -> Self {
        Self {
            mode,
            stack: Vec::new(),
        }
    }

    fn enter(&mut self, state: State) {
        self.stack.push(state);
    }
}

// ── Состояния ─────────────────────────────────────────────────────────────────
fn state_validating(machine: &mut InitMachine) -> Result<()> {
    machine.enter(State::Validating);

    let config_path = std::path::Path::new("/etc/upac/config.toml");
    if !config_path.exists() {
        anyhow::bail!(
            "config file not found: /etc/upac/config.toml\n\
             Create it before running init. Example:\n\
             \n\
             [paths]\n\
             db_path     = \"/var/db/upac\"\n\
             repo_path   = \"/var/repo\"\n\
             root_path   = \"/\"\n\
             ostree_path = \"/var/ostree\"\n\
             \n\
             [ostree]\n\
             enabled = false\n\
             branch  = \"packages\""
        );
    }

    state_initializing(machine)
}

fn state_initializing(machine: &mut InitMachine) -> Result<()> {
    machine.enter(State::Initializing);

    let config = crate::config::Config::load()?;

    let pb = spinner("Initializing system directories...");

    let lib = UpacLib::load()?;

    let paths = CSystemPaths {
        ostree_path: CSlice::from_str(&config.paths.ostree_path),
        repo_path: CSlice::from_str(&config.paths.repo_path),
        db_path: CSlice::from_str(&config.paths.db_path),
    };

    let code = unsafe { (lib.init_system)(paths, machine.mode) };

    pb.finish_and_clear();
    UpacLib::check(code, "init")?;

    state_done(machine)
}

fn state_done(machine: &mut InitMachine) -> Result<()> {
    machine.enter(State::Done);

    println!("{} system initialized", "✓".green().bold());
    println!(
        "  {}",
        "Run 'upac list' to verify the installation.".dimmed()
    );

    Ok(())
}

// ── Публичное API ─────────────────────────────────────────────────────────────
pub fn run(mode: String) -> Result<()> {
    let repo_mode = match mode.as_str() {
        "archive" => CRepoMode::Archive,
        "bare" => CRepoMode::Bare,
        "bare-user" => CRepoMode::BareUser,
        _ => anyhow::bail!("unknown mode '{mode}'. Available: archive, bare, bare-user"),
    };

    let mut machine = InitMachine::new(repo_mode);

    state_validating(&mut machine).map_err(|err| {
        if !matches!(machine.stack.last(), Some(State::Failed(_))) {
            machine.enter(State::Failed(err.to_string()));
        }
        eprintln!(
            "{} failed at state {:?}",
            "✗".red().bold(),
            machine.stack.last()
        );
        err
    })
}

// ── Хелперы ───────────────────────────────────────────────────────────────────
fn spinner(msg: &str) -> ProgressBar {
    let pb = ProgressBar::new_spinner();
    pb.set_style(
        ProgressStyle::default_spinner()
            .tick_strings(&["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"])
            .template("{spinner:.cyan} {msg}")
            .unwrap(),
    );
    pb.set_message(msg.to_owned());
    pb.enable_steady_tick(Duration::from_millis(80));
    pb
}
