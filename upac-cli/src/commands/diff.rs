use anyhow::Result;

use colored::Colorize;

use std::slice;

use crate::config::Config;
use crate::ffi::{CCommitArray, CDiffArray, CSlice, UpacLib, UpacLibGuard};

// ── FSM ───────────────────────────────────────────────────────────────────────
#[derive(Debug, Clone, PartialEq)]
enum State {
    Validating,
    FetchingDiff,
    Printing,
    Done,
    Failed(String),
}

struct DiffRow {
    path: String,
    kind: DiffKind,
}

#[derive(Debug, Clone, PartialEq)]
enum DiffKind {
    Added,
    Removed,
    Modified,
}

struct DiffMachine {
    config: Config,
    from: Option<String>,
    to: Option<String>,

    resolved_from: String,
    resolved_to: String,
    diff_entries: Vec<DiffRow>,

    upac_lib: Option<UpacLibGuard>,
    stack: Vec<State>,
}

impl DiffMachine {
    fn new(config: Config, from: Option<String>, to: Option<String>) -> Self {
        Self {
            config,
            from,
            to,

            resolved_from: String::new(),
            resolved_to: String::new(),

            diff_entries: Vec::new(),

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

    let mut c_diff = CDiffArray {
        ptr: std::ptr::null_mut(),
        len: 0,
    };

    let code = unsafe {
        (machine.upac_lib.as_ref().unwrap().diff)(
            CSlice::from_str(&machine.config.paths.repo_path),
            CSlice::from_str(&machine.resolved_from),
            CSlice::from_str(&machine.resolved_to),
            &mut c_diff,
        )
    };
    UpacLib::check(code, "diff")?;

    let entries = unsafe { slice::from_raw_parts(c_diff.ptr, c_diff.len) };
    machine.diff_entries = entries
        .iter()
        .map(|entry| unsafe {
            DiffRow {
                path: entry.path.as_str().to_owned(),
                kind: match entry.kind {
                    crate::ffi::CDiffKind::Added => DiffKind::Added,
                    crate::ffi::CDiffKind::Removed => DiffKind::Removed,
                    crate::ffi::CDiffKind::Modified => DiffKind::Modified,
                },
            }
        })
        .collect();

    unsafe { (machine.upac_lib.as_ref().unwrap().diff_free)(&mut c_diff) };

    state_printing(machine)
}

fn state_printing(machine: &mut DiffMachine) -> Result<()> {
    machine.enter(State::Printing);

    if machine.diff_entries.is_empty() {
        println!("{}", "No changes.".dimmed());
    } else {
        println!(
            "{} {} → {}",
            "diff:".dimmed(),
            &machine.resolved_from[..12].cyan(),
            &machine.resolved_to[..12].cyan(),
        );
        println!();
        for row in &machine.diff_entries {
            match row.kind {
                DiffKind::Added => println!("{} {}", "+".green().bold(), row.path),
                DiffKind::Removed => println!("{} {}", "-".red().bold(), row.path),
                DiffKind::Modified => println!("{} {}", "~".yellow().bold(), row.path),
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
pub fn run(config: Config, from: Option<String>, to: Option<String>) -> Result<()> {
    let mut machine = DiffMachine::new(config, from, to);

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
