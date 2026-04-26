// ── Imports ─────────────────────────────────────────────────────────────────
use indicatif::{ProgressBar, ProgressStyle};

use std::time::Duration;

use std::ptr::null_mut;
use std::slice;

use super::{
    Colorize, DiffMachine, FileDiffKind, FileDiffRow, PackageDiffRow, PkgDiffKind, Result, State,
    UpacLib,
};

use crate::ffi::{
    CAttributedDiffArray, CCommitArray, CDiffKind, CPackageDiffArray, CPackageDiffKind, CSlice,
};

// ── States ─────────────────────────────────────────────────────────────────
pub fn state_validating(machine: &mut DiffMachine) -> Result<()> {
    machine.enter(State::Validating);
    spinner(&machine.progress_bar, "Fetching diff...");

    match (&machine.from.clone(), &machine.to.clone()) {
        (Some(from), Some(to)) => {
            machine.resolved_from = from.clone();
            machine.resolved_to = to.clone();
        }
        _ => {
            let mut commits_c = CCommitArray {
                ptr: std::ptr::null_mut(),
                len: 0,
            };

            let return_code = unsafe {
                (machine.upac_lib.as_ref().list_commits)(
                    CSlice::from_str(&machine.config.paths.repo_path),
                    CSlice::from_str(&machine.config.ostree.branch),
                    &mut commits_c,
                )
            };
            UpacLib::check(return_code, "list commits")?;

            let entries = unsafe { slice::from_raw_parts(commits_c.ptr, commits_c.len) };
            let checksums: Vec<String> = entries
                .iter()
                .map(|entry| unsafe { entry.checksum.as_str().to_owned() })
                .collect();

            unsafe { (machine.upac_lib.as_ref().commits_free)(&mut commits_c) };

            if checksums.is_empty() {
                anyhow::bail!("no commits found");
            }

            match &machine.from.clone() {
                Some(from) => {
                    machine.resolved_from = from.clone();
                    machine.resolved_to = checksums[0].clone();
                }
                None => {
                    if checksums.len() < 2 {
                        anyhow::bail!("need at least two commits for diff");
                    }
                    machine.resolved_from = checksums[1].clone();
                    machine.resolved_to = checksums[0].clone();
                }
            }
        }
    }

    state_fetching_diff(machine)
}

fn state_fetching_diff(machine: &mut DiffMachine) -> Result<()> {
    machine.enter(State::FetchingDiff);

    if machine.files_mode {
        let mut attributed_diff_array_c = CAttributedDiffArray {
            ptr: null_mut(),
            len: 0,
        };

        UpacLib::check(
            unsafe {
                (machine.upac_lib.as_ref().diff_files_attributed)(
                    CSlice::from_str(&machine.config.paths.repo_path),
                    CSlice::from_str(&machine.resolved_from),
                    CSlice::from_str(&machine.resolved_to),
                    CSlice::from_str(&machine.config.paths.root_path),
                    CSlice::from_str(&machine.config.paths.database_path),
                    &mut attributed_diff_array_c,
                )
            },
            "diff files attributed",
        )?;

        let entries = unsafe {
            slice::from_raw_parts(attributed_diff_array_c.ptr, attributed_diff_array_c.len)
        };
        machine.file_rows = entries
            .iter()
            .map(|attributed_diff_array_c| unsafe {
                FileDiffRow {
                    path: attributed_diff_array_c.path.as_str().to_owned(),
                    kind: match attributed_diff_array_c.kind {
                        CDiffKind::Added => FileDiffKind::Added,
                        CDiffKind::Removed => FileDiffKind::Removed,
                        CDiffKind::Modified => FileDiffKind::Modified,
                    },
                    package_name: attributed_diff_array_c.package_name.as_str().to_owned(),
                }
            })
            .collect();

        unsafe {
            (machine.upac_lib.as_ref().diff_files_attributed_free)(&mut attributed_diff_array_c)
        };
    } else {
        let mut c_out = CPackageDiffArray {
            ptr: std::ptr::null_mut(),
            len: 0,
        };

        UpacLib::check(
            unsafe {
                (machine.upac_lib.as_ref().diff_packages)(
                    CSlice::from_str(&machine.config.paths.repo_path),
                    CSlice::from_str(&machine.resolved_from),
                    CSlice::from_str(&machine.resolved_to),
                    &mut c_out,
                )
            },
            "diff packages",
        )?;

        let entries = unsafe { slice::from_raw_parts(c_out.ptr, c_out.len) };
        machine.package_rows = entries
            .iter()
            .map(|package_diff_entry_c| unsafe {
                PackageDiffRow {
                    name: package_diff_entry_c.name.as_str().to_owned(),
                    kind: match package_diff_entry_c.kind {
                        CPackageDiffKind::Added => PkgDiffKind::Added,
                        CPackageDiffKind::Removed => PkgDiffKind::Removed,
                        CPackageDiffKind::Updated => PkgDiffKind::Updated,
                    },
                }
            })
            .collect();

        unsafe { (machine.upac_lib.as_ref().diff_packages_free)(&mut c_out) };
    }

    state_printing(machine)
}

fn state_printing(machine: &mut DiffMachine) -> Result<()> {
    machine.enter(State::Printing);

    let from_short = &machine.resolved_from[..machine.resolved_from.len().min(12)];
    let to_short = &machine.resolved_to[..machine.resolved_to.len().min(12)];

    if machine.files_mode {
        if machine.file_rows.is_empty() {
            println!("{}", "No file changes.".dimmed());
        } else {
            println!(
                "{} {} → {}",
                "diff --files:".dimmed(),
                from_short.cyan(),
                to_short.cyan(),
            );
            println!();
            for row in &machine.file_rows {
                let (symbol, path_colored) = match row.kind {
                    FileDiffKind::Added => ("+".green().bold(), row.path.as_str().normal()),
                    FileDiffKind::Removed => ("-".red().bold(), row.path.as_str().normal()),
                    FileDiffKind::Modified => ("~".yellow().bold(), row.path.as_str().normal()),
                };
                if row.package_name.is_empty() {
                    println!("{} {}", symbol, path_colored);
                } else {
                    println!(
                        "{} {} ({})",
                        symbol,
                        path_colored,
                        row.package_name.dimmed()
                    );
                }
            }
        }
    } else {
        if machine.package_rows.is_empty() {
            println!("{}", "No package changes.".dimmed());
        } else {
            println!(
                "{} {} → {}",
                "diff:".dimmed(),
                from_short.cyan(),
                to_short.cyan(),
            );
            println!();
            for row in &machine.package_rows {
                match row.kind {
                    PkgDiffKind::Added => println!("{} {}", "+".green().bold(), row.name.bold()),
                    PkgDiffKind::Removed => println!("{} {}", "-".red().bold(), row.name.bold()),
                    PkgDiffKind::Updated => println!("{} {}", "~".yellow().bold(), row.name.bold()),
                }
            }
        }
    }

    state_done(machine)
}

fn state_done(machine: &mut DiffMachine) -> Result<()> {
    machine.enter(State::Done);
    machine.progress_bar.finish_and_clear();

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
