// ── Imports ─────────────────────────────────────────────────────────────────
use indicatif::{ProgressBar, ProgressStyle};

use std::time::Duration;

use super::{Colorize, Result, RollbackMachine, State, UpacLib, UpacLibGuard};

use crate::ffi::{CRollbackRequest, CSlice};

// ── States ─────────────────────────────────────────────────────────────────
pub fn state_validating(machine: &mut RollbackMachine) -> Result<()> {
    machine.enter(State::Validating);
    machine.upac_lib = Some(UpacLibGuard::load()?);
    machine.progress_bar = Some(spinner("Rolling back..."));

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

    machine.progress_bar.as_ref().unwrap().println(format!(
        "{} rolling back to {}",
        "→".cyan(),
        &machine.commit_hash[..12].dimmed()
    ));

    state_rolling_back(machine)
}

fn state_rolling_back(machine: &mut RollbackMachine) -> Result<()> {
    machine.enter(State::RollingBack);

    let rollback_request_c = CRollbackRequest {
        root_path: CSlice::from_str(&machine.config.paths.root_path),
        repo_path: CSlice::from_str(&machine.config.paths.repo_path),

        branch: CSlice::from_str(&machine.config.ostree.branch),

        commit_hash: CSlice::from_str(&machine.commit_hash),
    };

    let return_code = unsafe { (machine.upac_lib.as_ref().unwrap().rollback)(rollback_request_c) };

    UpacLib::check(return_code, "rollback")?;

    state_done(machine)
}

fn state_done(machine: &mut RollbackMachine) -> Result<()> {
    machine.enter(State::Done);
    machine.progress_bar.as_ref().unwrap().finish_and_clear();

    println!(
        "{} rolled back to {}",
        "✓".green().bold(),
        &machine.commit_hash[..12].bold()
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
