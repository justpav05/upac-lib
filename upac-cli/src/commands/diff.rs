use anyhow::Result;

use colored::Colorize;

use std::slice;

use crate::config::Config;
use crate::ffi::{
    CAttributedDiffArray, CCommitArray, CDiffKind, CPackageDiffArray, CPackageDiffKind, CSlice,
    UpacLib, UpacLibGuard,
};

// ── FSM ───────────────────────────────────────────────────────────────────────
#[derive(Debug, Clone, PartialEq)]
enum State {
    Validating,
    FetchingDiff,
    Printing,
    Done,
    Failed(String),
}

struct PackageDiffRow {
    name: String,
    kind: PkgDiffKind,
}

#[derive(Debug, Clone, PartialEq)]
enum PkgDiffKind {
    Added,
    Removed,
    Updated,
}

struct FileDiffRow {
    path: String,
    kind: FileDiffKind,
    package_name: String,
}

#[derive(Debug, Clone, PartialEq)]
enum FileDiffKind {
    Added,
    Removed,
    Modified,
}

struct DiffMachine {
    config: Config,
    from: Option<String>,
    to: Option<String>,
    files_mode: bool,

    resolved_from: String,
    resolved_to: String,

    package_rows: Vec<PackageDiffRow>,
    file_rows: Vec<FileDiffRow>,

    upac_lib: Option<UpacLibGuard>,
    stack: Vec<State>,
}

impl DiffMachine {
    fn new(config: Config, from: Option<String>, to: Option<String>, files_mode: bool) -> Self {
        Self {
            config,
            from,
            to,
            files_mode,
            resolved_from: String::new(),
            resolved_to: String::new(),
            package_rows: Vec::new(),
            file_rows: Vec::new(),
            upac_lib: None,
            stack: Vec::new(),
        }
    }

    fn enter(&mut self, state: State) {
        self.stack.push(state);
    }
}

// ── Состояния ─────────────────────────────────────────────────────────────────
fn state_validating(machine: &mut DiffMachine) -> Result<()> {
    machine.enter(State::Validating);
    machine.upac_lib = Some(UpacLibGuard::load()?);

    match (&machine.from.clone(), &machine.to.clone()) {
        (Some(from), Some(to)) => {
            machine.resolved_from = from.clone();
            machine.resolved_to = to.clone();
        }
        _ => {
            let mut c_commits = CCommitArray {
                ptr: std::ptr::null_mut(),
                len: 0,
            };

            let code = unsafe {
                (machine.upac_lib.as_ref().unwrap().list_commits)(
                    CSlice::from_str(&machine.config.paths.repo_path),
                    CSlice::from_str(&machine.config.ostree.branch),
                    &mut c_commits,
                )
            };
            UpacLib::check(code, "list commits")?;

            let entries = unsafe { slice::from_raw_parts(c_commits.ptr, c_commits.len) };
            let checksums: Vec<String> = entries
                .iter()
                .map(|entry| unsafe { entry.checksum.as_str().to_owned() })
                .collect();

            unsafe { (machine.upac_lib.as_ref().unwrap().commits_free)(&mut c_commits) };

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
    let lib = machine.upac_lib.as_ref().unwrap();

    if machine.files_mode {
        let mut c_out = CAttributedDiffArray {
            ptr: std::ptr::null_mut(),
            len: 0,
        };

        let code = unsafe {
            (lib.diff_files_attributed)(
                CSlice::from_str(&machine.config.paths.repo_path),
                CSlice::from_str(&machine.resolved_from),
                CSlice::from_str(&machine.resolved_to),
                CSlice::from_str(&machine.config.paths.root_path),
                CSlice::from_str(&machine.config.paths.database_path),
                &mut c_out,
            )
        };
        UpacLib::check(code, "diff files attributed")?;

        let entries = unsafe { slice::from_raw_parts(c_out.ptr, c_out.len) };
        machine.file_rows = entries
            .iter()
            .map(|e| unsafe {
                FileDiffRow {
                    path: e.path.as_str().to_owned(),
                    kind: match e.kind {
                        CDiffKind::Added => FileDiffKind::Added,
                        CDiffKind::Removed => FileDiffKind::Removed,
                        CDiffKind::Modified => FileDiffKind::Modified,
                    },
                    package_name: e.package_name.as_str().to_owned(),
                }
            })
            .collect();

        unsafe { (lib.diff_files_attributed_free)(&mut c_out) };
    } else {
        let mut c_out = CPackageDiffArray {
            ptr: std::ptr::null_mut(),
            len: 0,
        };

        let code = unsafe {
            (lib.diff_packages)(
                CSlice::from_str(&machine.config.paths.repo_path),
                CSlice::from_str(&machine.resolved_from),
                CSlice::from_str(&machine.resolved_to),
                &mut c_out,
            )
        };
        UpacLib::check(code, "diff packages")?;

        let entries = unsafe { slice::from_raw_parts(c_out.ptr, c_out.len) };
        machine.package_rows = entries
            .iter()
            .map(|e| unsafe {
                PackageDiffRow {
                    name: e.name.as_str().to_owned(),
                    kind: match e.kind {
                        CPackageDiffKind::Added => PkgDiffKind::Added,
                        CPackageDiffKind::Removed => PkgDiffKind::Removed,
                        CPackageDiffKind::Updated => PkgDiffKind::Updated,
                    },
                }
            })
            .collect();

        unsafe { (lib.diff_packages_free)(&mut c_out) };
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
    Ok(())
}

// ── Публичное API ─────────────────────────────────────────────────────────────
pub fn run(
    config: Config,
    from: Option<String>,
    to: Option<String>,
    files_mode: bool,
) -> Result<()> {
    let mut machine = DiffMachine::new(config, from, to, files_mode);

    state_validating(&mut machine).map_err(|err| {
        let last_state = machine.stack.last().cloned();
        if !matches!(last_state, Some(State::Failed(_))) {
            machine.enter(State::Failed(err.to_string()));
        }
        if machine.config.verbose {
            eprintln!(
                "{} failed at state {:?}",
                "✗".red().bold(),
                machine.stack.last()
            );
        }
        err
    })
}
