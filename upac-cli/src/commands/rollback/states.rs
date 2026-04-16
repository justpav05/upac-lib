// ── Imports ─────────────────────────────────────────────────────────────────
use indicatif::{ProgressBar, ProgressStyle};

use std::time::Duration;

use super::{Colorize, Result, RollbackMachine, State};

use crate::ffi::{CRollbackRequest, CSlice, UpacLib, UpacLibGuard};

// ── States ─────────────────────────────────────────────────────────────────
pub fn state_validating(rolling_machine: &mut RollbackMachine) -> Result<()> {
    rolling_machine.enter(State::Validating);

    if rolling_machine.commit_hash.len() != 64
        || !rolling_machine
            .commit_hash
            .chars()
            .all(|char| char.is_ascii_hexdigit())
    {
        anyhow::bail!(
            "invalid commit hash '{}'. Expected 64 hex characters",
            rolling_machine.commit_hash
        );
    }

    println!(
        "{} rolling back to {}",
        "→".cyan(),
        &rolling_machine.commit_hash[..12].dimmed()
    );

    state_rolling_back(rolling_machine)
}

fn state_rolling_back(rolling_machine: &mut RollbackMachine) -> Result<()> {
    rolling_machine.enter(State::RollingBack);

    let progress_bar = spinner("Rolling back...");

    let upac_lib = UpacLibGuard::load()?;

    let c_rollback_request = CRollbackRequest {
        root_path: CSlice::from_str(&rolling_machine.config.paths.root_path),
        repo_path: CSlice::from_str(&rolling_machine.config.paths.repo_path),

        branch: CSlice::from_str(&rolling_machine.config.ostree.branch),

        commit_hash: CSlice::from_str(&rolling_machine.commit_hash),
    };

    let return_code = unsafe { (upac_lib.rollback)(c_rollback_request) };

    progress_bar.finish_and_clear();
    UpacLib::check(return_code, "rollback")?;

    state_done(rolling_machine)
}

fn state_done(machine: &mut RollbackMachine) -> Result<()> {
    machine.enter(State::Done);
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
