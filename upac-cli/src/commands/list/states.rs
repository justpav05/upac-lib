// ── Imports ─────────────────────────────────────────────────────────────────
use std::ffi::c_void;
use std::ptr::null_mut;
use std::slice;

use super::{
    format_size, Colorize, CommitRow, HandleGuard, ListMachine, PackageRow, Result, State, UpacLib,
    UpacLibGuard,
};

use crate::ffi::{CCommitArray, CSlice};

// ── States ─────────────────────────────────────────────────────────────────
pub fn state_fetching_mode(machine: &mut ListMachine) -> Result<()> {
    machine.enter(State::FetchingMode);
    machine.upac_lib = Some(UpacLibGuard::load()?);

    match machine.commits_mode {
        true => state_get_commits_info(machine),
        false => state_get_packages_list(machine),
    }
}

fn state_get_commits_info(machine: &mut ListMachine) -> Result<()> {
    machine.enter(State::GetPackages);

    let repo_path_c = CSlice::from_str(&machine.config.paths.repo_path);
    let branch_c = CSlice::from_str(&machine.config.ostree.branch);

    let mut commit_array_c = CCommitArray {
        ptr: null_mut(),
        len: 0,
    };

    let return_code = unsafe {
        (machine.upac_lib.as_ref().unwrap().list_commits)(
            repo_path_c,
            branch_c,
            &mut commit_array_c,
        )
    };
    UpacLib::check(return_code, "list commits")?;

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

    unsafe { (machine.upac_lib.as_ref().unwrap().commits_free)(&mut commit_array_c) };

    state_printing_commits(machine)
}

fn state_get_packages_list(machine: &mut ListMachine) -> Result<()> {
    machine.enter(State::GetPackages);

    let mut handle: *mut c_void = null_mut();

    let return_code = unsafe {
        (machine.upac_lib.as_ref().unwrap().list_packages)(
            CSlice::from_str(&machine.config.paths.repo_path),
            CSlice::from_str(&machine.config.ostree.branch),
            CSlice::from_str(&machine.config.paths.database_path),
            &mut handle,
        )
    };
    UpacLib::check(return_code, "list packages")?;

    let free_fn = machine.upac_lib.as_ref().unwrap().packages_free;
    let count_fn = machine.upac_lib.as_ref().unwrap().packages_count;
    let get_name = machine.upac_lib.as_ref().unwrap().package_get_name;
    let get_version = machine.upac_lib.as_ref().unwrap().package_get_version;
    let get_size = machine.upac_lib.as_ref().unwrap().package_get_size;
    let get_architecture = machine.upac_lib.as_ref().unwrap().package_get_architecture;
    let get_author = machine.upac_lib.as_ref().unwrap().package_get_author;
    let get_license = machine.upac_lib.as_ref().unwrap().package_get_license;
    let get_url = machine.upac_lib.as_ref().unwrap().package_get_url;
    let get_packager = machine.upac_lib.as_ref().unwrap().package_get_packager;

    let guard = HandleGuard::new(handle, free_fn);

    let count = unsafe { count_fn(guard.handle) };

    machine.packages = (0..count)
        .map(|i| unsafe {
            PackageRow {
                name: get_name(guard.handle, i).as_str().to_owned(),
                version: get_version(guard.handle, i).as_str().to_owned(),
                size: get_size(guard.handle, i),
                architecture: get_architecture(guard.handle, i).as_str().to_owned(),
                author: get_author(guard.handle, i).as_str().to_owned(),
                license: get_license(guard.handle, i).as_str().to_owned(),
                url: get_url(guard.handle, i).as_str().to_owned(),
                packager: get_packager(guard.handle, i).as_str().to_owned(),
            }
        })
        .collect();
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
    Ok(())
}
