// ── Imports ─────────────────────────────────────────────────────────────────
use std::slice;

use super::{Colorize, CommitRow, ListMachine, PackageRow, Result, State};

use crate::ffi::{CCommitArray, CPackageMetaArray, CSlice, UpacLib, UpacLibGuard};

// ── States ─────────────────────────────────────────────────────────────────
pub fn state_fetching_commits(machine: &mut ListMachine) -> Result<()> {
    machine.enter(State::FetchingCommits);

    let upac_lib = UpacLibGuard::load()?;

    if machine.commits_mode {
        let repo_path_c = CSlice::from_str(&machine.config.paths.repo_path);
        let branch_c = CSlice::from_str(&machine.config.ostree.branch);

        let mut c_commits = CCommitArray {
            ptr: std::ptr::null_mut(),
            len: 0,
        };

        let code = unsafe { (upac_lib.list_commits)(repo_path_c, branch_c, &mut c_commits) };
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
        let mut packages_meta_c = CPackageMetaArray {
            ptr: std::ptr::null_mut(),
            len: 0,
        };

        let code = unsafe {
            (upac_lib.list_packages)(
                CSlice::from_str(&machine.config.paths.repo_path),
                CSlice::from_str(&machine.config.ostree.branch),
                CSlice::from_str(&machine.config.paths.database_path),
                &mut packages_meta_c,
            )
        };
        UpacLib::check(code, "list packages")?;

        let entries = unsafe { slice::from_raw_parts(packages_meta_c.ptr, packages_meta_c.len) };
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

        unsafe { (upac_lib.packages_free)(&mut packages_meta_c) };
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
                    println!("{}", pkg.name.as_str().bold());
                    println!("  {} {}", "version:".dimmed(), pkg.version.as_str());
                    println!("  {} {}", "author: ".dimmed(), pkg.author.as_str());
                    println!("  {} {}", "license:".dimmed(), pkg.license.as_str());
                    println!();
                } else {
                    println!(
                        "{} {}",
                        pkg.name.as_str().bold(),
                        pkg.version.as_str().dimmed()
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
