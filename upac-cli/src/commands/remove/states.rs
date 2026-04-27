// ── Imports ─────────────────────────────────────────────────────────────────
use indicatif::{ProgressBar, ProgressStyle};

use std::time::Duration;

use super::{c_void, on_remove_progress, Colorize, RemoveMachine, Result, State, UpacLib};

use crate::ffi::{CSlice, CUninstallRequest};

// ── States ─────────────────────────────────────────────────────────────────
pub fn state_validating(machine: &mut RemoveMachine) -> Result<()> {
    machine.enter(State::Validating);
    spinner(&machine.progress_bar, "Removing packages...");

    for name in &machine.package_names {
        if name.is_empty() {
            anyhow::bail!("Package name cannot be empty");
        }
        machine
            .progress_bar
            .println(format!("{} removing {}", "→".cyan(), name.bold()));
    }

    state_uninstalling(machine)
}

fn state_uninstalling(machine: &mut RemoveMachine) -> Result<()> {
    machine.enter(State::Uninstalling);

    let package_names_c: Vec<CSlice> = machine
        .package_names
        .iter()
        .map(|name| CSlice::from_str(name))
        .collect();

    let progress_bar_ptr = &machine.progress_bar as *const ProgressBar as *mut c_void;

    let remove_request_c = CUninstallRequest::new(
        package_names_c.as_slice(),
        &machine.config.paths.repo_path.to_str()?,
        &machine.config.paths.root_path.to_str()?,
        &machine.config.paths.database_path.to_str()?,
        &machine.config.ostree.branch.to_str()?,
        &machine.config.ostree.prefix_directory.to_str()?,
        machine.config.step_retries,
        Some(on_remove_progress),
        progress_bar_ptr,
    );

    UpacLib::check(
        unsafe { (machine.upac_lib.as_ref().uninstall)(remove_request_c) },
        "uninstall",
    )?;

    state_done(machine)
}

fn state_done(machine: &mut RemoveMachine) -> Result<()> {
    machine.enter(State::Done);
    machine.progress_bar.finish_and_clear();

    for name in &machine.package_names {
        machine
            .progress_bar
            .println(format!("{} removed {}", "✓".green().bold(), name.bold()));
    }

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
    progress_bar.println(message);
    progress_bar.enable_steady_tick(Duration::from_millis(80));
}
