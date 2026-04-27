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
    Validate,
};

// ── States ─────────────────────────────────────────────────────────────────
pub fn state_validating(machine: &mut DiffMachine) -> Result<()> {
    machine.enter(State::Validating);
    spinner(&machine.progress_bar, "Checking diff set up...");

    let has_valid_args = match (&machine.from_commit, &machine.to_commit) {
        (Some(f), Some(t)) => !f.is_empty() && !t.is_empty(),
        _ => false,
    };

    if !has_valid_args {
        let mut checksums = fetch_commit_checksums(machine)?;
        if checksums.len() < 2 {
            anyhow::bail!("need at least two commits for diff");
        }

        machine.from_commit = Some(checksums.remove(1));
        machine.to_commit = Some(checksums.remove(0));
    }

    match machine.files_mode {
        true => state_fetching_files_diff(machine),
        false => state_fetching_packages_diff(machine),
    }
}

fn fetch_commit_checksums(machine: &mut DiffMachine) -> Result<Vec<String>> {
    machine.enter(State::Validating);
    spinner(&machine.progress_bar, "Fetching commit checksums...");

    let mut commit_array_c = CCommitArray {
        ptr: null_mut(),
        len: 0,
    };

    UpacLib::check(
        unsafe {
            (machine.upac_lib.as_ref().list_commits)(
                CSlice::from_str(&machine.config.paths.repo_path.to_str()?),
                CSlice::from_str(&machine.config.ostree.branch.to_str()?),
                &mut commit_array_c,
            )
        },
        "list commits",
    )?;
    let commit_array = unsafe { slice::from_raw_parts(commit_array_c.ptr, commit_array_c.len) };

    let checksums = commit_array
        .iter()
        .map(|commit_entry| {
            commit_entry.validate()?;
            Ok(unsafe { commit_entry.checksum.as_str().to_owned() })
        })
        .collect::<Result<Vec<_>>>()?;

    unsafe { (machine.upac_lib.as_ref().commits_free)(&mut commit_array_c) };

    Ok(checksums)
}

fn state_fetching_files_diff(machine: &mut DiffMachine) -> Result<()> {
    machine.enter(State::FetchingFilesDiff);
    spinner(&machine.progress_bar, "Fetching file diff...");

    let mut attributed_diff_array_c = CAttributedDiffArray {
        ptr: null_mut(),
        len: 0,
    };

    UpacLib::check(
        unsafe {
            (machine.upac_lib.as_ref().diff_files_attributed)(
                CSlice::from_str(&machine.config.paths.repo_path.to_str()?),
                CSlice::from_str(&machine.from_commit.as_ref().unwrap()),
                CSlice::from_str(&machine.to_commit.as_ref().unwrap()),
                CSlice::from_str(&machine.config.paths.root_path.to_str()?),
                CSlice::from_str(&machine.config.paths.database_path.to_str()?),
                &mut attributed_diff_array_c,
            )
        },
        "diff files attributed",
    )?;

    let entries =
        unsafe { slice::from_raw_parts(attributed_diff_array_c.ptr, attributed_diff_array_c.len) };

    machine.file_rows = entries
        .iter()
        .map(|entry| {
            entry.validate()?;
            Ok(unsafe {
                FileDiffRow {
                    path: entry.path.as_str().to_owned(),
                    kind: match entry.kind {
                        CDiffKind::Added => FileDiffKind::Added,
                        CDiffKind::Removed => FileDiffKind::Removed,
                        CDiffKind::Modified => FileDiffKind::Modified,
                    },
                    package_name: entry.package_name.as_str().to_owned(),
                }
            })
        })
        .collect::<Result<Vec<_>>>()?;

    unsafe { (machine.upac_lib.as_ref().diff_files_attributed_free)(&mut attributed_diff_array_c) };

    state_printing_files_diff(machine)
}

fn state_fetching_packages_diff(machine: &mut DiffMachine) -> Result<()> {
    machine.enter(State::FetchingPackagesDiff);
    spinner(&machine.progress_bar, "Fetching package diff...");

    let mut package_array_c = CPackageDiffArray {
        ptr: null_mut(),
        len: 0,
    };

    UpacLib::check(
        unsafe {
            (machine.upac_lib.as_ref().diff_packages)(
                CSlice::from_str(&machine.config.paths.repo_path.to_str()?),
                CSlice::from_str(&machine.from_commit.as_ref().unwrap()),
                CSlice::from_str(&machine.to_commit.as_ref().unwrap()),
                &mut package_array_c,
            )
        },
        "diff packages",
    )?;

    let entries = unsafe { slice::from_raw_parts(package_array_c.ptr, package_array_c.len) };

    machine.package_rows = entries
        .iter()
        .map(|entry| {
            entry.validate()?;
            Ok(unsafe {
                PackageDiffRow {
                    name: entry.name.as_str().to_owned(),
                    kind: match entry.kind {
                        CPackageDiffKind::Added => PkgDiffKind::Added,
                        CPackageDiffKind::Removed => PkgDiffKind::Removed,
                        CPackageDiffKind::Updated => PkgDiffKind::Updated,
                    },
                }
            })
        })
        .collect::<Result<Vec<_>>>()?;

    unsafe { (machine.upac_lib.as_ref().diff_packages_free)(&mut package_array_c) };

    state_printing_packages_diff(machine)
}

fn state_printing_files_diff(machine: &mut DiffMachine) -> Result<()> {
    machine.enter(State::PrintingFilesDiff);
    spinner(&machine.progress_bar, "Print files diff...");

    let from_commit_unwraped_short = &machine.from_commit.as_ref().unwrap()
        [..machine.from_commit.as_ref().unwrap().len().min(12)];
    let to_commit_unwraped_short =
        &machine.to_commit.as_ref().unwrap()[..machine.to_commit.as_ref().unwrap().len().min(12)];

    println!(
        "{} {} → {}",
        "diff --files:\n".dimmed(),
        from_commit_unwraped_short.cyan(),
        to_commit_unwraped_short.cyan(),
    );

    if machine.file_rows.is_empty() {
        println!("{}", "No file changes.".dimmed());
        return state_done(machine);
    }

    for row in &machine.file_rows {
        let (symbol, path_colored) = match row.kind {
            FileDiffKind::Added => ("+".green().bold(), row.path.as_str().normal()),
            FileDiffKind::Removed => ("-".red().bold(), row.path.as_str().normal()),
            FileDiffKind::Modified => ("~".yellow().bold(), row.path.as_str().normal()),
        };
        match row.package_name.is_empty() {
            true => println!("{} {}", symbol, path_colored),
            false => println!(
                "{} {} ({})",
                symbol,
                path_colored,
                row.package_name.dimmed()
            ),
        }
    }

    state_done(machine)
}

fn state_printing_packages_diff(machine: &mut DiffMachine) -> Result<()> {
    machine.enter(State::PrintingPackagesDiff);
    spinner(&machine.progress_bar, "Print package diff...");

    let from_commit_unwraped_short = &machine.from_commit.as_ref().unwrap()
        [..machine.from_commit.as_ref().unwrap().len().min(12)];
    let to_commit_unwraped_short =
        &machine.to_commit.as_ref().unwrap()[..machine.to_commit.as_ref().unwrap().len().min(12)];

    println!(
        "{} {} → {}",
        "diff:\n".dimmed(),
        from_commit_unwraped_short.cyan(),
        to_commit_unwraped_short.cyan(),
    );

    if machine.package_rows.is_empty() {
        println!("{}", "No package changes.".dimmed());
        return state_done(machine);
    }

    println!();
    for row in &machine.package_rows {
        match row.kind {
            PkgDiffKind::Added => println!("{} {}", "+".green().bold(), row.name.bold()),
            PkgDiffKind::Removed => println!("{} {}", "-".red().bold(), row.name.bold()),
            PkgDiffKind::Updated => println!("{} {}", "~".yellow().bold(), row.name.bold()),
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
