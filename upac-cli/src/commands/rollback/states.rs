// ── Imports ─────────────────────────────────────────────────────────────────
use indicatif::{ProgressBar, ProgressStyle};

use std::time::Duration;

use super::{Colorize, Result, RollbackMachine, State, UpacLib};

use crate::ffi::{CRollbackRequest, CSlice};

// ── States ─────────────────────────────────────────────────────────────────
pub fn state_validating(machine: &mut RollbackMachine) -> Result<()> {
    machine.enter(State::Validating);
    spinner(&machine.progress_bar, "Validating rolling data...");

    if machine.commit_hash.len() != 64
        || !machine
            .commit_hash
            .chars()
            .all(|char| char.is_ascii_hexdigit())
    {
        anyhow::bail!(
            "invalid commit hash '{}'. Expected 64 hex characters",
            machine.commit_hash
        );
    }

    machine.progress_bar.println(format!(
        "{} rolling back to {}",
        "→".cyan(),
        &machine.commit_hash[..12].dimmed()
    ));

    state_rolling_back(machine)
}

fn state_rolling_back(machine: &mut RollbackMachine) -> Result<()> {
    machine.enter(State::RollingBack);
    spinner(&machine.progress_bar, "Rolling back...");

    let rollback_request_c = CRollbackRequest {
        struct_size: std::mem::size_of::<CRollbackRequest>(),

        root_path: CSlice::from_str(&machine.config.paths.root_path),
        repo_path: CSlice::from_str(&machine.config.paths.repo_path),

        branch: CSlice::from_str(&machine.config.ostree.branch),
        prefix_directory: CSlice::from_str(&machine.config.ostree.prefix_directory),

        commit_hash: CSlice::from_str(&machine.commit_hash),
    };

    UpacLib::check(
        unsafe { (machine.upac_lib.as_ref().rollback)(rollback_request_c) },
        "rollback",
    )?;

    state_done(machine)
}

fn state_done(machine: &mut RollbackMachine) -> Result<()> {
    machine.enter(State::Done);
    machine.progress_bar.finish_and_clear();

    println!(
        "{} rolled back to {}",
        "✓".green().bold(),
        &machine.commit_hash[..12].bold()
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
