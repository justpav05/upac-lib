// ── Imports ─────────────────────────────────────────────────────────────────
use indicatif::{ProgressBar, ProgressStyle};

use std::time::Duration;

use std::path::Path;

use super::{Colorize, InitMachine, Result, State};

use crate::ffi::{CInitRequest, CSlice, CSystemPaths, UpacLib, UpacLibGuard};

// ── States ─────────────────────────────────────────────────────────────────
pub fn state_validating(init_machine: &mut InitMachine) -> Result<()> {
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
             repo_path   = \"/var/repo\"\n\
             root_path   = \"/\"\n\
             \n\
             [ostree]\n\
             branch  = \"packages\"",
            init_machine.config.paths.config_path
        );
    }

    state_initializing(init_machine)
}

fn state_initializing(init_machine: &mut InitMachine) -> Result<()> {
    init_machine.enter(State::Initializing);

    let progress_bar = spinner("Initializing system directories...");

    let upac_lib = UpacLibGuard::load()?;

    let system_paths_c = CSystemPaths {
        repo_path: CSlice::from_str(&init_machine.config.paths.repo_path),
        root_path: CSlice::from_str(&init_machine.config.paths.root_path),
    };

    let branch_c = CSlice::from_str(&init_machine.config.ostree.branch);

    let init_request_c = CInitRequest {
        system_paths: system_paths_c,
        repo_mode: init_machine.repo_mode_c,
        branch: branch_c,
    };

    let return_code = unsafe { (upac_lib.init)(init_request_c) };
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

// ── Helpers ───────────────────────────────────────────────────────────────────
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
