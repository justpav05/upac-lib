// ── Imports ─────────────────────────────────────────────────────────────────
use indicatif::{ProgressBar, ProgressStyle};

use std::time::Duration;

use std::path::Path;

use super::{Colorize, InitMachine, Result, State, UpacLib};

use crate::ffi::{CInitRequest, CSliceArray};

// ── States ─────────────────────────────────────────────────────────────────
pub fn state_validating(machine: &mut InitMachine) -> Result<()> {
    machine.enter(State::Validating);
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
    machine.enter(State::Initializing);
    spinner(&machine.progress_bar, "Initializing system directories...");

    let init_request_c = CInitRequest::new(
        &machine.config.paths.repo_path.to_str()?,
        &machine.config.paths.root_path.to_str()?,
        &machine.config.ostree.prefix_directory.to_str()?,
        CSliceArray::empty(),
        machine.repo_mode_c,
        &machine.config.ostree.branch.to_str()?,
    );

    UpacLib::check(
        unsafe { (machine.upac_lib.as_ref().init)(init_request_c) },
        "init",
    )?;

    state_done(machine)
}

fn state_done(machine: &mut InitMachine) -> Result<()> {
    machine.enter(State::Done);
    machine.progress_bar.finish_and_clear();

    println!("{} system initialized", "✓".green().bold());
    println!(
        "  {}",
        "Run 'upac list' to verify the installation.".dimmed()
    );

    unsafe { (machine.upac_lib.as_ref().deinit)() };

    Ok(())
}

// ── Helpers ───────────────────────────────────────────────────────────────────
fn spinner(progress_bar: &ProgressBar, message: &str) -> () {
    progress_bar.set_style(
        ProgressStyle::default_spinner()
            .tick_strings(&["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"])
            .template("{spinner:.cyan} {msg}")
            .unwrap(),
    );
    progress_bar.set_message(message.to_owned());
    progress_bar.enable_steady_tick(Duration::from_millis(80));
}
