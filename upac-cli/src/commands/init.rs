// ── Imports ─────────────────────────────────────────────────────────────────
use anyhow::Result;

use indicatif::ProgressBar;

use colored::Colorize;

use std::path::Path;
use std::sync::Arc;

use crate::config::Config;
use crate::ffi::{CArray, CRepoMode, CUnmutatedRequest};
use crate::upac::UpacLib;
use crate::utils::{spinner, BackendKind};

// ── Arguments for command ───────────────────────────────────────────────────────────────────────
#[derive(clap::Args)]
pub struct InitArgs {
    #[arg(long, default_value = "/etc/upac/config.toml")]
    pub config_path: String,
}

// ── FSM states ───────────────────────────────────────────────────────────────────────
#[derive(Debug, Clone, PartialEq)]
enum State {
    Validating,
    Initializing,

    Done,
}

// ── FSM machine ───────────────────────────────────────────────────────────────────────
struct InitMachine {
    repo_mode_c: CRepoMode,

    config_path: String,

    config: Config,
    progress_bar: ProgressBar,
    upac_lib: Arc<UpacLib>,
    state: State,
}

impl InitMachine {
    fn new(repo_mode_c: CRepoMode, config_path: String, config: Config) -> Result<Self> {
        Ok(Self {
            repo_mode_c,

            config_path,

            config,
            progress_bar: ProgressBar::new_spinner(),
            upac_lib: Arc::new(UpacLib::load(&BackendKind::UpacLib)?),
            state: State::Validating,
        })
    }
}

// ── Public API ─────────────────────────────────────────────────────────────
pub fn run(config: Config, args: InitArgs) -> Result<()> {
    let repo_mode_c = match config.ostree.mode.to_str()? {
        "archive" => CRepoMode::Archive,
        "bare" => CRepoMode::Bare,
        "bare-user" => CRepoMode::BareUser,
        _ => anyhow::bail!(
            "unknown mode '{}'. Available: archive, bare, bare-user",
            config.ostree.mode.to_str()?
        ),
    };

    let mut init_machine = InitMachine::new(repo_mode_c, args.config_path, config)?;

    state_validating(&mut init_machine).map_err(|err| {
        if init_machine.config.verbose {
            eprintln!(
                "{} failed at state {:?}",
                "✗".red().bold(),
                init_machine.state
            );
        }
        err
    })
}

// ── States ─────────────────────────────────────────────────────────────────
fn state_validating(machine: &mut InitMachine) -> Result<()> {
    machine.state = State::Validating;
    spinner(&machine.progress_bar, "Checking config...");

    let config_path = Path::new(&machine.config_path);

    if !config_path.exists() {
        anyhow::bail!(
            "config file not found: {}\n\
             Create it before running init. Example:\n\
             \n\
             verbose = false\n\
             \n\
             [paths]\n\
             repo_path   = \"/var/repo\"\n\
             root_path   = \"/\"\n\
             \n\
             [ostree]\n\
             branch  = \"packages\"",
            machine.config_path
        );
    }

    state_initializing(machine)
}

fn state_initializing(machine: &mut InitMachine) -> Result<()> {
    machine.state = State::Initializing;
    spinner(&machine.progress_bar, "Initializing system directories...");

    let init_request_c = CUnmutatedRequest::new(
        &machine.config.paths.repo_path.to_owned(),
        &machine.config.paths.root_path.to_owned(),
        &machine.config.ostree.prefix_directory.to_owned(),
        machine.repo_mode_c,
        &machine.config.ostree.branch.to_owned(),
    );

    UpacLib::check(
        unsafe { (machine.upac_lib.as_ref().init)(init_request_c) },
        "init",
    )?;

    state_done(machine)
}

fn state_done(machine: &mut InitMachine) -> Result<()> {
    machine.state = State::Done;
    machine.progress_bar.finish_and_clear();

    println!("{} system initialized", "✓".green().bold());
    println!(
        "  {}",
        "Run 'upac list' to verify the installation.".dimmed()
    );

    Ok(())
}
