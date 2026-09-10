// SPDX-FileCopyrightText: 2026 JustPav
// SPDX-FileCopyrightText: 2026 SmoothTeam
//
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

use std::fs::{File, write};

use composefs::generic_tree::Stat;
use composefs::repository::{ImportContext, Repository, RepositoryConfig};
use composefs::tree::FileSystem;
use nix::fcntl::AT_FDCWD;
use tempfile::{Builder, TempDir};
use upac::composefs::file::FileHandle;
use upac::composefs::repository::ObjectID;
use upac::config::merge_config;

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

fn insert(
    repository: &Repository<ObjectID>, tree: &mut FileSystem<ObjectID>, ctx: &mut ImportContext, label: &str,
    path: &str, content: &[u8],
) {
    FileHandle::new(path)
        .insert_file(
            repository,
            tree,
            &source_file(label, content),
            Stat::uninitialized(),
            ctx,
        )
        .unwrap();
}

fn read(repository: &Repository<ObjectID>, tree: &FileSystem<ObjectID>, path: &str) -> Vec<u8> {
    FileHandle::new(path).read_file(repository, tree).unwrap()
}

fn exists(tree: &FileSystem<ObjectID>, path: &str) -> bool {
    FileHandle::new(path).stat_in_tree(tree).is_ok()
}

#[test]
fn untouched_file_keeps_the_new_package_default() {
    let (_scratch, repository) = open_repository("untouched");
    let mut ctx = ImportContext::default();

    let mut base = empty_tree();
    insert(&repository, &mut base, &mut ctx, "untouched-base", "conf", b"base");
    let live = base.clone();

    let mut new = empty_tree();
    insert(&repository, &mut new, &mut ctx, "untouched-new", "conf", b"new");

    let result = merge_config(&base, &new, &live, true).unwrap();

    assert_eq!(read(&repository, &result.tree, "conf"), b"new");
    assert!(result.conflicts.is_empty());
}

#[test]
fn user_only_edit_is_kept_when_package_did_not_change_the_file() {
    let (_scratch, repository) = open_repository("user-only-edit");
    let mut ctx = ImportContext::default();

    let mut base = empty_tree();
    insert(&repository, &mut base, &mut ctx, "user-only-edit-base", "conf", b"base");
    let new = base.clone();

    let mut live = empty_tree();
    insert(
        &repository,
        &mut live,
        &mut ctx,
        "user-only-edit-live",
        "conf",
        b"user-edit",
    );

    let result = merge_config(&base, &new, &live, true).unwrap();

    assert_eq!(read(&repository, &result.tree, "conf"), b"user-edit");
    assert!(result.conflicts.is_empty());
}

#[test]
fn conflicting_edit_keeps_the_user_version_and_writes_upac_new_sidecar() {
    let (_scratch, repository) = open_repository("conflict-edit");
    let mut ctx = ImportContext::default();

    let mut base = empty_tree();
    insert(&repository, &mut base, &mut ctx, "conflict-edit-base", "conf", b"base");

    let mut new = empty_tree();
    insert(
        &repository,
        &mut new,
        &mut ctx,
        "conflict-edit-new",
        "conf",
        b"package-new",
    );

    let mut live = empty_tree();
    insert(
        &repository,
        &mut live,
        &mut ctx,
        "conflict-edit-live",
        "conf",
        b"user-edit",
    );

    let result = merge_config(&base, &new, &live, true).unwrap();

    assert_eq!(read(&repository, &result.tree, "conf"), b"user-edit");
    assert_eq!(read(&repository, &result.tree, "conf.upac-new"), b"package-new");
    assert_eq!(result.conflicts, vec!["conf".to_owned()]);
}

#[test]
fn conflicting_edit_skips_the_upac_new_sidecar_when_conflict_files_are_disallowed() {
    let (_scratch, repository) = open_repository("conflict-edit-no-sidecar");
    let mut ctx = ImportContext::default();

    let mut base = empty_tree();
    insert(
        &repository,
        &mut base,
        &mut ctx,
        "conflict-edit-no-sidecar-base",
        "conf",
        b"base",
    );

    let mut new = empty_tree();
    insert(
        &repository,
        &mut new,
        &mut ctx,
        "conflict-edit-no-sidecar-new",
        "conf",
        b"package-new",
    );

    let mut live = empty_tree();
    insert(
        &repository,
        &mut live,
        &mut ctx,
        "conflict-edit-no-sidecar-live",
        "conf",
        b"user-edit",
    );

    let result = merge_config(&base, &new, &live, false).unwrap();

    assert_eq!(read(&repository, &result.tree, "conf"), b"user-edit");
    assert!(!exists(&result.tree, "conf.upac-new"));
    assert_eq!(result.conflicts, vec!["conf".to_owned()]);
}

#[test]
fn user_deletion_is_carried_over_when_the_package_did_not_change_the_file() {
    let (_scratch, repository) = open_repository("user-deletion");
    let mut ctx = ImportContext::default();

    let mut base = empty_tree();
    insert(&repository, &mut base, &mut ctx, "user-deletion-base", "conf", b"base");
    let new = base.clone();
    let live = empty_tree();

    let result = merge_config(&base, &new, &live, true).unwrap();

    assert!(!exists(&result.tree, "conf"));
    assert!(result.conflicts.is_empty());
}

#[test]
fn user_deletion_conflicts_when_the_package_also_changed_the_file() {
    let (_scratch, repository) = open_repository("user-deletion-conflict");
    let mut ctx = ImportContext::default();

    let mut base = empty_tree();
    insert(
        &repository,
        &mut base,
        &mut ctx,
        "user-deletion-conflict-base",
        "conf",
        b"base",
    );

    let mut new = empty_tree();
    insert(
        &repository,
        &mut new,
        &mut ctx,
        "user-deletion-conflict-new",
        "conf",
        b"package-new",
    );

    let live = empty_tree();

    let result = merge_config(&base, &new, &live, true).unwrap();

    assert_eq!(read(&repository, &result.tree, "conf"), b"package-new");
    assert!(!exists(&result.tree, "conf.upac-new"));
    assert_eq!(result.conflicts, vec!["conf".to_owned()]);
}

#[test]
fn user_edit_survives_when_the_package_stops_providing_the_file() {
    let (_scratch, repository) = open_repository("orphaned-edit");
    let mut ctx = ImportContext::default();

    let mut base = empty_tree();
    insert(&repository, &mut base, &mut ctx, "orphaned-edit-base", "conf", b"base");

    let new = empty_tree();

    let mut live = empty_tree();
    insert(
        &repository,
        &mut live,
        &mut ctx,
        "orphaned-edit-live",
        "conf",
        b"user-edit",
    );

    let result = merge_config(&base, &new, &live, true).unwrap();

    assert_eq!(read(&repository, &result.tree, "conf"), b"user-edit");
    assert!(!exists(&result.tree, "conf.upac-new"));
    assert!(result.conflicts.is_empty());
}

#[test]
fn user_deletion_is_not_a_conflict_when_the_package_also_removed_the_file() {
    let (_scratch, repository) = open_repository("agreed-deletion");
    let mut ctx = ImportContext::default();

    let mut base = empty_tree();
    insert(
        &repository,
        &mut base,
        &mut ctx,
        "agreed-deletion-base",
        "conf",
        b"base",
    );

    let new = empty_tree();
    let live = empty_tree();

    let result = merge_config(&base, &new, &live, true).unwrap();

    assert!(!exists(&result.tree, "conf"));
    assert!(result.conflicts.is_empty());
}

#[test]
fn brand_new_user_file_survives_the_merge() {
    let (_scratch, repository) = open_repository("brand-new-user-file");
    let mut ctx = ImportContext::default();

    let base = empty_tree();
    let new = empty_tree();

    let mut live = empty_tree();
    insert(
        &repository,
        &mut live,
        &mut ctx,
        "brand-new-user-file-live",
        "conf",
        b"user-only",
    );

    let result = merge_config(&base, &new, &live, true).unwrap();

    assert_eq!(read(&repository, &result.tree, "conf"), b"user-only");
    assert!(result.conflicts.is_empty());
}
