// ── Imports ─────────────────────────────────────────────────────────────────
use anyhow::Result;

use colored::Colorize;

use std::ffi::c_void;
use std::ptr::null_mut;
use std::slice;
use std::sync::Arc;

use crate::config::Config;
use crate::ffi::{CCommitArray, CSlice};
use crate::upac::UpacLib;
use crate::utils::BackendKind;

// ── Row types ────────────────────────────────────────────────────────────────────────
struct PackageRow {
    name: String,
    version: String,
    size: u32,
    architecture: String,
    author: String,
    license: String,
    url: String,
    packager: String,
}

struct CommitRow {
    checksum: String,
    subject: String,
}

impl CommitRow {
    pub fn new(checksum: String, subject: String) -> Self {
        Self { checksum, subject }
    }
}

// ── Arguments for command ───────────────────────────────────────────────────────────────────────
#[derive(clap::Args)]
pub struct ListArgs {
    #[arg(long)]
    pub commit: bool,
    #[arg(long)]
    pub full: bool,
}

// ── FSM states ────────────────────────────────────────────────────────────────────────
#[derive(Debug, Clone, PartialEq)]
enum State {
    Starting,
    GetPackages,
    GetCommits,
    PrintCommits,
    PrintPackages,

    Done,
}

// ── FSM machine ────────────────────────────────────────────────────────────────────────
struct ListMachine {
    full: bool,
    commits_mode: bool,

    commits: Vec<CommitRow>,
    packages: Vec<PackageRow>,

    config: Config,
    upac_lib: Arc<UpacLib>,
    state: State,
}

impl ListMachine {
    fn new(config: Config, commits_mode: bool, full: bool) -> Result<Self> {
        Ok(Self {
            full,

            commits_mode,
            packages: Vec::new(),

            commits: Vec::new(),

            config,
            upac_lib: Arc::new(UpacLib::load(&BackendKind::UpacLib)?),
            state: State::Starting,
        })
    }
}

// ── Public API ─────────────────────────────────────────────────────────────
pub fn run(config: Config, args: ListArgs) -> Result<()> {
    let mut list_machine = ListMachine::new(config, args.commit, args.full)?;

    match list_machine.commits_mode {
        true => state_get_commits_info(&mut list_machine).map_err(|err| {
            if list_machine.config.verbose {
                eprintln!(
                    "{} failed at state {:?}",
                    "✗".red().bold(),
                    list_machine.state
                );
            }
            err
        }),
        false => state_get_packages_list(&mut list_machine).map_err(|err| {
            if list_machine.config.verbose {
                eprintln!(
                    "{} failed at state {:?}",
                    "✗".red().bold(),
                    list_machine.state
                );
            }
            err
        }),
    }
}

// ── States ─────────────────────────────────────────────────────────────────
fn state_get_commits_info(machine: &mut ListMachine) -> Result<()> {
    machine.state = State::GetCommits;

    let repo_path_c = CSlice::from_str(&machine.config.paths.repo_path.to_str()?);
    let branch_c = CSlice::from_str(&machine.config.ostree.branch.to_str()?);

    let mut commit_array_c = CCommitArray {
        ptr: null_mut(),
        len: 0,
    };

    UpacLib::check(
        unsafe {
            (machine.upac_lib.as_ref().list_commits)(repo_path_c, branch_c, &mut commit_array_c)
        },
        "list commits",
    )?;

    let commit_entries = unsafe { slice::from_raw_parts(commit_array_c.ptr, commit_array_c.len) };
    machine.commits = commit_entries
        .iter()
        .map(|entry| unsafe {
            CommitRow::new(
                entry.checksum.as_str().to_owned(),
                entry.subject.as_str().to_owned(),
            )
        })
        .collect();

    unsafe { (machine.upac_lib.as_ref().commits_free)(&mut commit_array_c) };

    state_printing_commits(machine)
}

fn state_get_packages_list(machine: &mut ListMachine) -> Result<()> {
    machine.state = State::GetPackages;

    let mut package_list: *mut c_void = null_mut();

    UpacLib::check(
        unsafe {
            (machine.upac_lib.as_ref().list_packages)(
                CSlice::from_str(&machine.config.paths.repo_path.to_str()?),
                CSlice::from_str(&machine.config.ostree.branch.to_str()?),
                CSlice::from_str(&machine.config.paths.database_path.to_str()?),
                &mut package_list,
            )
        },
        "list packages",
    )?;

    let package_count = unsafe { (machine.upac_lib.as_ref().packages_count)(package_list) };

    machine.packages = (0..package_count)
        .map(|index| -> Result<PackageRow> {
            let mut name = CSlice {
                ptr: null_mut(),
                len: 0,
            };
            let mut version = CSlice {
                ptr: null_mut(),
                len: 0,
            };
            let mut architecture = CSlice {
                ptr: null_mut(),
                len: 0,
            };
            let mut author = CSlice {
                ptr: null_mut(),
                len: 0,
            };
            let mut license = CSlice {
                ptr: null_mut(),
                len: 0,
            };
            let mut url = CSlice {
                ptr: null_mut(),
                len: 0,
            };
            let mut packager = CSlice {
                ptr: null_mut(),
                len: 0,
            };
            let mut size: u32 = 0;

            unsafe {
                UpacLib::check(
                    (machine.upac_lib.as_ref().package_get_slice_field)(
                        package_list,
                        index,
                        0,
                        &mut name,
                    ),
                    "get name",
                )?;
                UpacLib::check(
                    (machine.upac_lib.as_ref().package_get_slice_field)(
                        package_list,
                        index,
                        1,
                        &mut version,
                    ),
                    "get version",
                )?;
                UpacLib::check(
                    (machine.upac_lib.as_ref().package_get_slice_field)(
                        package_list,
                        index,
                        2,
                        &mut architecture,
                    ),
                    "get architecture",
                )?;
                UpacLib::check(
                    (machine.upac_lib.as_ref().package_get_slice_field)(
                        package_list,
                        index,
                        3,
                        &mut author,
                    ),
                    "get author",
                )?;
                UpacLib::check(
                    (machine.upac_lib.as_ref().package_get_slice_field)(
                        package_list,
                        index,
                        5,
                        &mut license,
                    ),
                    "get license",
                )?;
                UpacLib::check(
                    (machine.upac_lib.as_ref().package_get_slice_field)(
                        package_list,
                        index,
                        6,
                        &mut url,
                    ),
                    "get url",
                )?;
                UpacLib::check(
                    (machine.upac_lib.as_ref().package_get_slice_field)(
                        package_list,
                        index,
                        7,
                        &mut packager,
                    ),
                    "get packager",
                )?;
                UpacLib::check(
                    (machine.upac_lib.as_ref().package_get_int_field)(
                        package_list,
                        index,
                        9,
                        &mut size,
                    ),
                    "get size",
                )?;

                Ok(PackageRow {
                    name: name.as_str().to_owned(),
                    version: version.as_str().to_owned(),
                    architecture: architecture.as_str().to_owned(),
                    author: author.as_str().to_owned(),
                    license: license.as_str().to_owned(),
                    url: url.as_str().to_owned(),
                    packager: packager.as_str().to_owned(),
                    size,
                })
            }
        })
        .collect::<Result<Vec<_>>>()?;

    unsafe { (machine.upac_lib.as_ref().packages_free)(package_list) };

    state_printing_packeges(machine)
}

fn state_printing_commits(machine: &mut ListMachine) -> Result<()> {
    machine.state = State::PrintCommits;

    if machine.commits.is_empty() {
        println!("{}", "No commits found.".dimmed());
        return state_done(machine);
    }

    for row in &machine.commits {
        match machine.full {
            true => {
                println!("{}", &row.checksum[..12].bold().cyan());
                println!("  {} {}", "subject:".dimmed(), row.subject);
                println!("  {} {}", "hash:   ".dimmed(), row.checksum);
                println!();
            }
            false => {
                println!(
                    "{} {}",
                    &row.checksum[..12].bold().cyan(),
                    row.subject.dimmed()
                );
            }
        }
    }

    state_done(machine)
}

fn state_printing_packeges(machine: &mut ListMachine) -> Result<()> {
    machine.state = State::PrintPackages;

    if machine.packages.is_empty() {
        println!("{}", "No packages installed.".dimmed());
        return state_done(machine);
    }

    for package_row in &machine.packages {
        if machine.full {
            println!("{}", package_row.name.as_str().bold());
            println!(
                "  {} {}",
                "version: ".dimmed(),
                package_row.version.as_str()
            );
            println!("  {} {}", "size: ".dimmed(), format_size(package_row.size));
            println!(
                "  {} {}",
                "arch: ".dimmed(),
                package_row.architecture.as_str()
            );
            println!("  {} {}", "author: ".dimmed(), package_row.author.as_str());
            println!(
                "  {} {}",
                "packager: ".dimmed(),
                package_row.packager.as_str()
            );
            println!(
                "  {} {}",
                "license: ".dimmed(),
                package_row.license.as_str()
            );
            println!("  {} {}", "url: ".dimmed(), package_row.url.as_str());
            println!();
        } else {
            println!(
                "{} {}",
                package_row.name.as_str().bold(),
                package_row.version.as_str().dimmed()
            );
        }
    }

    state_done(machine)
}

fn state_done(machine: &mut ListMachine) -> Result<()> {
    machine.state = State::Done;

    Ok(())
}

// ── Helpers ───────────────────────────────────────────────────────────────────
pub fn format_size(bytes: u32) -> String {
    const KB: u32 = 1024;
    const MB: u32 = 1024 * KB;
    const GB: u32 = 1024 * MB;

    if bytes >= GB {
        format!("{:.1} GiB", bytes as f64 / GB as f64)
    } else if bytes >= MB {
        format!("{:.1} MiB", bytes as f64 / MB as f64)
    } else if bytes >= KB {
        format!("{:.1} KiB", bytes as f64 / KB as f64)
    } else {
        format!("{} B", bytes)
    }
}
