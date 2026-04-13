use anyhow::Result;

use colored::Colorize;

use std::slice;

use crate::config::Config;
use crate::ffi::{CCommitArray, CPackageMeta, CPackageMetaArray, CSlice, UpacLib, UpacLibGuard};

// ── FSM ───────────────────────────────────────────────────────────────────────
#[derive(Debug, Clone, PartialEq)]
enum State {
    FetchingCommits,
    Printing,
    Done,
    Failed(String),
}

struct PackageRow {
    name: String,
    version: String,
    author: String,
    license: String,
}

struct CommitRow {
    checksum: String,
    subject: String,
}

struct ListMachine {
    config: Config,
    full: bool,
    commits_mode: bool,

    commits: Vec<CommitRow>,
    packages: Vec<PackageRow>,

    stack: Vec<State>,
}

impl ListMachine {
    fn new(config: Config, commits_mode: bool, full: bool) -> Self {
        Self {
            config,
            full,

            commits_mode,
            packages: Vec::new(),

            commits: Vec::new(),

            stack: Vec::new(),
        }
    }

    fn enter(&mut self, state: State) {
        self.stack.push(state);
    }
}

// ── Состояния ─────────────────────────────────────────────────────────────────
fn state_fetching_commits(machine: &mut ListMachine) -> Result<()> {
    machine.enter(State::FetchingCommits);

    let upac_lib = UpacLibGuard::load()?;

    if machine.commits_mode {
        let c_repo_path = CSlice::from_str(&machine.config.paths.repo_path);
        let c_branch = CSlice::from_str(&machine.config.ostree.branch);

        let mut c_commits = CCommitArray {
            ptr: std::ptr::null_mut(),
            len: 0,
        };

        let code = unsafe { (upac_lib.list_commits)(c_repo_path, c_branch, &mut c_commits) };
        UpacLib::check(code, "list commits")?;

        let entries = unsafe { slice::from_raw_parts(c_commits.ptr, c_commits.len) };
        machine.commits = entries
            .iter()
            .map(|entry| unsafe {
                CommitRow {
                    checksum: entry.checksum.as_str().to_owned(),
                    subject: entry.subject.as_str().to_owned(),
                }
            })
            .collect();

        unsafe { (upac_lib.commits_free)(&mut c_commits) };
    } else {
        let mut c_packages = CPackageMetaArray {
            ptr: std::ptr::null_mut(),
            len: 0,
        };

        let code = unsafe {
            (upac_lib.list_packages)(
                CSlice::from_str(&machine.config.paths.repo_path),
                CSlice::from_str(&machine.config.ostree.branch),
                CSlice::from_str(&machine.config.paths.database_path),
                &mut c_packages,
            )
        };
        UpacLib::check(code, "list packages")?;

        let entries = unsafe { slice::from_raw_parts(c_packages.ptr, c_packages.len) };
        machine.packages = entries
            .iter()
            .map(|entry| unsafe {
                PackageRow {
                    name: entry.name.as_str().to_owned(),
                    version: entry.version.as_str().to_owned(),
                    author: entry.author.as_str().to_owned(),
                    license: entry.license.as_str().to_owned(),
                }
            })
            .collect();

        unsafe { (upac_lib.packages_free)(&mut c_packages) };
    }

    state_printing(machine)
}

fn state_printing(machine: &mut ListMachine) -> Result<()> {
    machine.enter(State::Printing);

    if machine.commits_mode {
        if machine.commits.is_empty() {
            println!("{}", "No commits found.".dimmed());
        } else {
            for row in &machine.commits {
                if machine.full {
                    println!("{}", &row.checksum[..12].bold().cyan());
                    println!("  {} {}", "subject:".dimmed(), row.subject);
                    println!("  {} {}", "hash:   ".dimmed(), row.checksum);
                    println!();
                } else {
                    println!(
                        "{} {}",
                        &row.checksum[..12].bold().cyan(),
                        row.subject.dimmed()
                    );
                }
            }
        }
    } else {
        if machine.packages.is_empty() {
            println!("{}", "No packages installed.".dimmed());
        } else {
            for pkg in &machine.packages {
                if machine.full {
                    println!("{}", unsafe { pkg.name.as_str() }.bold());
                    println!("  {} {}", "version:".dimmed(), unsafe {
                        pkg.version.as_str()
                    });
                    println!("  {} {}", "author: ".dimmed(), unsafe {
                        pkg.author.as_str()
                    });
                    println!("  {} {}", "license:".dimmed(), unsafe {
                        pkg.license.as_str()
                    });
                    println!();
                } else {
                    println!(
                        "{} {}",
                        unsafe { pkg.name.as_str() }.bold(),
                        unsafe { pkg.version.as_str() }.dimmed()
                    );
                }
            }
        }
    }

    state_done(machine)
}

fn state_done(machine: &mut ListMachine) -> Result<()> {
    machine.enter(State::Done);
    Ok(())
}

// ── Публичное API ─────────────────────────────────────────────────────────────
pub fn run(config: Config, commit: bool, full: bool) -> Result<()> {
    let mut machine = ListMachine::new(config, commit, full);

    state_fetching_commits(&mut machine).map_err(|err| {
        if !matches!(machine.stack.last(), Some(State::Failed(_))) {
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
