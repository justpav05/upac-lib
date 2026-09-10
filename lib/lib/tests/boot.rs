// SPDX-FileCopyrightText: 2026 JustPav
// SPDX-FileCopyrightText: 2026 SmoothTeam
//
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

use std::fs::{File, write};

use composefs::fsverity::FsVerityHashValue;
use composefs::generic_tree::Stat;
use composefs::repository::{ImportContext, Repository, RepositoryConfig};
use composefs::tree::FileSystem;
use nix::fcntl::AT_FDCWD;
use tempfile::{Builder, TempDir};

use upac::boot::error::BootError;
use upac::boot::write_boot_entry;
use upac::composefs::file::FileHandle;
use upac::composefs::repository::ObjectID;

fn scratch_dir(name: &str) -> TempDir {
    Builder::new().prefix(name).tempdir().unwrap()
}

fn empty_tree() -> FileSystem<ObjectID> {
    FileSystem::new(Stat::uninitialized())
}

fn open_repository(name: &str) -> (TempDir, Repository<ObjectID>) {
    let dir = scratch_dir(name);
    let (repository, _created) =
        Repository::init_path(AT_FDCWD, dir.path(), RepositoryConfig::default().set_insecure()).unwrap();

    (dir, repository)
}

fn source_file(dir_name: &str, content: &[u8]) -> File {
    let dir = scratch_dir(dir_name);
    let path = dir.path().join("source");
    write(&path, content).unwrap();

    File::open(&path).unwrap()
}

fn ensure_modules_dir(tree: &mut FileSystem<ObjectID>) {
    if FileHandle::from_tree(tree, "lib/modules").is_ok() {
        return;
    }
    FileHandle::new("lib")
        .insert_in_tree(tree, Stat::uninitialized())
        .unwrap();
    FileHandle::new("lib/modules")
        .insert_in_tree(tree, Stat::uninitialized())
        .unwrap();
}

fn insert_kernel(
    repository: &Repository<ObjectID>, tree: &mut FileSystem<ObjectID>, ctx: &mut ImportContext, kver: &str,
) {
    ensure_modules_dir(tree);
    FileHandle::new(format!("lib/modules/{kver}"))
        .insert_in_tree(tree, Stat::uninitialized())
        .unwrap();
    FileHandle::new(format!("lib/modules/{kver}/vmlinuz"))
        .insert_file(
            repository,
            tree,
            &source_file(&format!("kernel-{kver}"), b"kernel"),
            Stat::uninitialized(),
            ctx,
        )
        .unwrap();
}

#[test]
fn write_boot_entry_fails_when_the_tree_has_no_boot_resource() {
    let (_scratch, repository) = open_repository("boot-none");
    let tree = empty_tree();
    let esp = scratch_dir("boot-none-esp");

    let result = write_boot_entry(&repository, &tree, ObjectID::EMPTY, esp.path(), "deadbeef");

    assert_eq!(result.unwrap_err(), BootError::NoBootResource);
}

#[test]
fn write_boot_entry_fails_when_the_tree_has_more_than_one_boot_resource() {
    let (_scratch, repository) = open_repository("boot-ambiguous");
    let mut ctx = ImportContext::default();
    let mut tree = empty_tree();
    insert_kernel(&repository, &mut tree, &mut ctx, "6.6.0");
    insert_kernel(&repository, &mut tree, &mut ctx, "6.7.0");
    let esp = scratch_dir("boot-ambiguous-esp");

    let result = write_boot_entry(&repository, &tree, ObjectID::EMPTY, esp.path(), "deadbeef");

    assert_eq!(result.unwrap_err(), BootError::AmbiguousBootResource);
}
