// ── Imports ─────────────────────────────────────────────────────────────────
use std::ffi::c_void;
use std::ptr::null_mut;
use std::slice;

use super::{
    format_size, Colorize, CommitRow, HandleGuard, ListMachine, PackageRow, Result, State, UpacLib,
};

use crate::ffi::{CCommitArray, CSlice};

// ── States ─────────────────────────────────────────────────────────────────
pub fn state_fetching_mode(machine: &mut ListMachine) -> Result<()> {
    machine.enter(State::FetchingMode);

    match machine.commits_mode {
        true => state_get_commits_info(machine),
        false => state_get_packages_list(machine),
    }
}

fn state_get_commits_info(machine: &mut ListMachine) -> Result<()> {
    machine.enter(State::GetCommits);

    let repo_path_c = CSlice::from_str(&machine.config.paths.repo_path);
    let branch_c = CSlice::from_str(&machine.config.ostree.branch);

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
            CommitRow {
                checksum: entry.checksum.as_str().to_owned(),
                subject: entry.subject.as_str().to_owned(),
            }
        })
        .collect();

    unsafe { (machine.upac_lib.as_ref().commits_free)(&mut commit_array_c) };

    state_printing_commits(machine)
}

fn state_get_packages_list(machine: &mut ListMachine) -> Result<()> {
    machine.enter(State::GetPackages);

    let mut handle: *mut c_void = null_mut();

    let return_code = unsafe {
        (machine.upac_lib.as_ref().list_packages)(
            CSlice::from_str(&machine.config.paths.repo_path),
            CSlice::from_str(&machine.config.ostree.branch),
            CSlice::from_str(&machine.config.paths.database_path),
            &mut handle,
        )
    };
    UpacLib::check(return_code, "list packages")?;

    let lib = machine.upac_lib.as_ref();
    let guard = HandleGuard::new(handle, lib.packages_free);
    let count = unsafe { (lib.packages_count)(guard.handle) };

    machine.packages = (0..count)
        .map(|i| -> Result<PackageRow> {
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
                    (lib.package_get_slice_field)(guard.handle, i, 0, &mut name),
                    "get name",
                )?;
                UpacLib::check(
                    (lib.package_get_slice_field)(guard.handle, i, 1, &mut version),
                    "get version",
                )?;
                UpacLib::check(
                    (lib.package_get_slice_field)(guard.handle, i, 2, &mut architecture),
                    "get architecture",
                )?;
                UpacLib::check(
                    (lib.package_get_slice_field)(guard.handle, i, 3, &mut author),
                    "get author",
                )?;
                UpacLib::check(
                    (lib.package_get_slice_field)(guard.handle, i, 5, &mut license),
                    "get license",
                )?;
                UpacLib::check(
                    (lib.package_get_slice_field)(guard.handle, i, 6, &mut url),
                    "get url",
                )?;
                UpacLib::check(
                    (lib.package_get_slice_field)(guard.handle, i, 7, &mut packager),
                    "get packager",
                )?;
                UpacLib::check(
                    (lib.package_get_int_field)(guard.handle, i, 9, &mut size),
                    "get size",
                )?;
            }

            Ok(PackageRow {
                name: unsafe { name.as_str() }.to_owned(),
                version: unsafe { version.as_str() }.to_owned(),
                architecture: unsafe { architecture.as_str() }.to_owned(),
                author: unsafe { author.as_str() }.to_owned(),
                license: unsafe { license.as_str() }.to_owned(),
                url: unsafe { url.as_str() }.to_owned(),
                packager: unsafe { packager.as_str() }.to_owned(),
                size,
            })
        })
        .collect::<Result<Vec<_>>>()?;

    state_printing_packeges(machine)
}

fn state_printing_commits(machine: &mut ListMachine) -> Result<()> {
    machine.enter(State::PrintCommits);

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
    machine.enter(State::PrintPackages);

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
    machine.enter(State::Done);

    (machine.upac_lib.as_ref().deinit);

    Ok(())
}
