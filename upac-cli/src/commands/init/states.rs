// ── Imports ─────────────────────────────────────────────────────────────────
use indicatif::{ProgressBar, ProgressStyle};

use std::time::Duration;

use std::path::Path;

use super::{Colorize, InitMachine, Result, State, UpacLib, UpacLibGuard};

use crate::ffi::{CInitRequest, CSlice, CSliceArray};

// ── States ─────────────────────────────────────────────────────────────────
pub fn state_validating(machine: &mut InitMachine) -> Result<()> {
    machine.enter(State::Validating);
    machine.upac_lib = Some(UpacLibGuard::load()?);

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

    let progress_bar = spinner("Initializing system directories...");

    let branch_c = CSlice::from_str(&machine.config.ostree.branch);

    let init_request_c = CInitRequest {
        struct_size: size_of::<CInitRequest>(),

        repo_path: CSlice::from_str(&machine.config.paths.repo_path),
        root_path: CSlice::from_str(&machine.config.paths.root_path),

        prefix_directory: CSlice::from_str(&machine.config.ostree.prefix_directory),
        addition_prefixes: CSliceArray::empty(),

        repo_mode: machine.repo_mode_c,
        branch: branch_c,
    };

    let return_code = unsafe { (machine.upac_lib.as_ref().unwrap().init)(init_request_c) };
    progress_bar.finish_and_clear();
    UpacLib::check(return_code, "init")?;

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
