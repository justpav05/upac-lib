use anyhow::Result;

use colored::Colorize;

use chrono::{LocalResult, TimeZone, Utc};

use std::mem::MaybeUninit;
use std::slice;

use crate::config::Config;
use crate::ffi::{CCommitArray, CPackageMeta, CSlice, CSliceArray, UpacLib};

// ── FSM ───────────────────────────────────────────────────────────────────────
#[derive(Debug, Clone, PartialEq)]
enum State {
    FetchingList,
    FetchingDetails,
    FetchingCommits,
    Printing,
    Done,
    Failed(String),
}

struct ListMachine {
    config: Config,
    versions: bool,
    full: bool,
    commit: bool,

    names: Vec<String>,
    details: Vec<PackageRow>,
    commits: Vec<CommitRow>,

    stack: Vec<State>,
}

struct PackageRow {
    name: String,
    version: String,
    author: String,
    description: String,
    license: String,
    installed_at: i64,
}

struct CommitRow {
    checksum: String,
    subject: String,
}

impl ListMachine {
    fn new(config: Config, versions: bool, commit: bool, full: bool) -> Self {
        Self {
            config,
            versions,
            commit,
            full,
            names: Vec::new(),
            details: Vec::new(),
            commits: Vec::new(),
            stack: Vec::new(),
        }
    }

    fn enter(&mut self, state: State) {
        self.stack.push(state);
    }
}

// ── Состояния ─────────────────────────────────────────────────────────────────
fn state_fetching_list(machine: &mut ListMachine) -> Result<()> {
    machine.enter(State::FetchingList);

    if machine.commit {
        return state_fetching_commits(machine);
    }

    let upac_lib = UpacLib::load()?;
    let database_path = CSlice::from_str(&machine.config.paths.database_path);

    let mut list = CSliceArray {
        ptr: std::ptr::null_mut(),
        len: 0,
    };
    let code = unsafe { (upac_lib.db_list_packages)(database_path, &mut list) };
    UpacLib::check(code, "list packages")?;

    let slices = unsafe { std::slice::from_raw_parts(list.ptr, list.len) };
    machine.names = slices
        .iter()
        .map(|string| unsafe { string.as_str().to_owned() })
        .collect();
    unsafe { (upac_lib.list_free)(&mut list) };

    if machine.names.is_empty() {
        println!("{}", "No packages installed.".dimmed());
        machine.enter(State::Done);
        return Ok(());
    }

    if !machine.versions && !machine.full {
        return state_printing(machine);
    }

    state_fetching_details(machine)
}

fn state_fetching_commits(machine: &mut ListMachine) -> Result<()> {
    machine.enter(State::FetchingCommits);

    if !machine.config.ostree.enabled {
        anyhow::bail!("OStree is disabled in config. Set ostree.enabled = true to use --commit");
    }

    let upac_lib = UpacLib::load()?;
    let c_repo_path = CSlice::from_str(&machine.config.paths.ostree_path);
    let c_branch = CSlice::from_str(&machine.config.ostree.branch);

    let mut c_commits = CCommitArray {
        ptr: std::ptr::null_mut(),
        len: 0,
    };

    let code = unsafe { (upac_lib.ostree_list_commits)(c_repo_path, c_branch, &mut c_commits) };
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

    state_printing(machine)
}

fn state_fetching_details(machine: &mut ListMachine) -> Result<()> {
    machine.enter(State::FetchingDetails);

    let upac_lib = UpacLib::load()?;
    let database_path = CSlice::from_str(&machine.config.paths.database_path);

    for name in &machine.names {
        let mut c_package_meta = MaybeUninit::<CPackageMeta>::uninit();
        let name_slice = CSlice::from_str(name);

        let operation_code = unsafe {
            (upac_lib.db_get_meta)(database_path, name_slice, c_package_meta.as_mut_ptr())
        };

        if operation_code != 0 {
            eprintln!("{} could not read metadata for {name}", "⚠".yellow());
            continue;
        }

        let meta = unsafe { c_package_meta.assume_init() };
        let row = unsafe {
            PackageRow {
                name: meta.name.as_str().to_owned(),
                version: meta.version.as_str().to_owned(),
                author: meta.author.as_str().to_owned(),
                description: meta.description.as_str().to_owned(),
                license: meta.license.as_str().to_owned(),
                installed_at: meta.installed_at,
            }
        };

        let mut meta_owned = meta;
        unsafe { (upac_lib.meta_free)(&mut meta_owned) };

        machine.details.push(row);
    }

    state_printing(machine)
}

fn state_printing(machine: &mut ListMachine) -> Result<()> {
    machine.enter(State::Printing);

    if machine.commit {
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
    } else if machine.full {
        for row in &machine.details {
            println!("{}", row.name.bold().green());
            println!("  {} {}", "version:".dimmed(), row.version);
            println!("  {} {}", "author: ".dimmed(), row.author);
            println!("  {} {}", "license:".dimmed(), row.license);
            if !row.description.is_empty() {
                println!("  {} {}", "desc:   ".dimmed(), row.description);
            }
            println!(
                "  {} {}",
                "installed:".dimmed(),
                format_timestamp(row.installed_at)
            );
            println!();
        }
    } else if machine.versions {
        for row in &machine.details {
            println!("{} {}", row.name.bold(), row.version.dimmed());
        }
    } else {
        for name in &machine.names {
            println!("{}", name.bold());
        }
    }

    state_done(machine)
}

fn state_done(machine: &mut ListMachine) -> Result<()> {
    machine.enter(State::Done);
    Ok(())
}

// ── Публичное API ─────────────────────────────────────────────────────────────
pub fn run(config: Config, versions: bool, commit: bool, full: bool) -> Result<()> {
    if versions && commit {
        anyhow::bail!("--versions and --commit are incompatible flags");
    }

    let mut machine = ListMachine::new(config, versions, commit, full);

    state_fetching_list(&mut machine).map_err(|err| {
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

// ── Хелперы ───────────────────────────────────────────────────────────────────
fn format_timestamp(ts: i64) -> String {
    if ts == 0 {
        return "unknown".to_owned();
    }

    match Utc.timestamp_opt(ts, 0) {
        LocalResult::Single(datetime) => datetime.format("%H:%M %d-%m-%Y ").to_string(),
        _ => format!("unix:{ts}"),
    }
}
