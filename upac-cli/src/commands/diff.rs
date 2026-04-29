// ── Imports ─────────────────────────────────────────────────────────────────
use anyhow::Result;

use indicatif::ProgressBar;

use colored::Colorize;

use clap::Args;

use std::ptr::null_mut;
use std::slice;
use std::sync::Arc;

use crate::config::Config;
use crate::upac::UpacLib;
use crate::utils::{spinner, BackendKind};

use crate::ffi::{
    CAttributedDiffArray, CCommitArray, CDiffKind, CPackageDiffArray, CPackageDiffKind, CSlice,
    Validate,
};

// ── Arguments for command ───────────────────────────────────────────────────────────────────────
#[derive(Args)]
pub struct DiffArgs {
    pub from: Option<String>,
    pub to: Option<String>,
    #[arg(long)]
    pub files: bool,
}

// ── FSM States ───────────────────────────────────────────────────────────────────────
#[derive(Debug, Clone, PartialEq)]
enum State {
    Validating,

    FetchingFilesDiff,
    FetchingPackagesDiff,

    PrintingFilesDiff,
    PrintingPackagesDiff,

    Done,
}

// ── Diff kinds ───────────────────────────────────────────────────────────────────────
#[derive(Debug, Clone, PartialEq)]
enum PkgDiffKind {
    Added,
    Removed,
    Updated,
}

#[derive(Debug, Clone, PartialEq)]
enum FileDiffKind {
    Added,
    Removed,
    Modified,
}

// ── Diff rows ───────────────────────────────────────────────────────────────────────
struct PackageDiffRow {
    name: String,
    kind: PkgDiffKind,
}

struct FileDiffRow {
    path: String,
    kind: FileDiffKind,
    package_name: String,
}

// ── DiffFSM machine ───────────────────────────────────────────────────────────────────────
struct DiffMachine {
    from_commit: Option<String>,
    to_commit: Option<String>,

    package_rows: Vec<PackageDiffRow>,
    file_rows: Vec<FileDiffRow>,

    files_mode: bool,

    upac_lib: Arc<UpacLib>,
    progress_bar: ProgressBar,
    config: Config,
    state: State,
}

impl DiffMachine {
    fn new(
        config: Config,
        from_commit: Option<String>,
        to_commit: Option<String>,
        files_mode: bool,
    ) -> Result<Self> {
        Ok(Self {
            from_commit,
            to_commit,
            package_rows: Vec::new(),
            file_rows: Vec::new(),
            files_mode,
            progress_bar: ProgressBar::new_spinner(),
            upac_lib: Arc::new(UpacLib::load(&BackendKind::UpacLib)?),
            config,
            state: State::Validating,
        })
    }
}

// ── Public API ─────────────────────────────────────────────────────────────
pub fn run(config: Config, args: DiffArgs) -> Result<()> {
    let mut diff_machine = DiffMachine::new(config, args.from, args.to, args.files)?;

    state_validating(&mut diff_machine).map_err(|err| {
        if diff_machine.config.verbose {
            eprintln!(
                "{} failed at state {:?}",
                "✗".red().bold(),
                diff_machine.state
            );
        }
        err
    })
}

// ── States ─────────────────────────────────────────────────────────────────
fn state_validating(machine: &mut DiffMachine) -> Result<()> {
    machine.state = State::Validating;
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
    machine.state = State::Validating;
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
    machine.state = State::FetchingFilesDiff;
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
    machine.state = State::FetchingPackagesDiff;
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
    machine.state = State::PrintingFilesDiff;
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
    machine.state = State::PrintingPackagesDiff;
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
    machine.state = State::Done;
    machine.progress_bar.finish_and_clear();

    Ok(())
}
