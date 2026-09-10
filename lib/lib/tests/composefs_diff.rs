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

use upac::composefs::diff::TreeDiff;
use upac::composefs::file::FileHandle;
use upac::composefs::repository::ObjectID;

use upac_abi::FileDiffKind;

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
    repository: &Repository<ObjectID>, tree: &mut FileSystem<ObjectID>, ctx: &mut ImportContext, path: &str,
    content: &[u8],
) {
    FileHandle::new(path)
        .insert_file(
            repository,
            tree,
            &source_file(&path.replace('/', "-"), content),
            Stat::uninitialized(),
            ctx,
        )
        .unwrap();
}

#[test]
fn run_reports_no_changes_for_identical_trees() {
    let (_scratch, repository) = open_repository("diff-unchanged");
    let mut ctx = ImportContext::default();
    let mut from = empty_tree();
    let mut to = empty_tree();
    insert(&repository, &mut from, &mut ctx, "file.txt", b"same");
    insert(&repository, &mut to, &mut ctx, "file.txt", b"same");

    let changes = TreeDiff::run(&from, &to);

    assert!(changes.is_empty());
}

#[test]
fn run_reports_added_for_a_file_only_in_to() {
    let (_scratch, repository) = open_repository("diff-added");
    let mut ctx = ImportContext::default();
    let from = empty_tree();
    let mut to = empty_tree();
    insert(&repository, &mut to, &mut ctx, "new.txt", b"content");

    let changes = TreeDiff::run(&from, &to);

    assert_eq!(changes, vec![("new.txt".to_owned(), FileDiffKind::Added)]);
}

#[test]
fn run_reports_removed_for_a_file_only_in_from() {
    let (_scratch, repository) = open_repository("diff-removed");
    let mut ctx = ImportContext::default();
    let mut from = empty_tree();
    let to = empty_tree();
    insert(&repository, &mut from, &mut ctx, "old.txt", b"content");

    let changes = TreeDiff::run(&from, &to);

    assert_eq!(changes, vec![("old.txt".to_owned(), FileDiffKind::Removed)]);
}

#[test]
fn run_reports_modified_for_a_file_with_different_content_in_each_tree() {
    let (_scratch, repository) = open_repository("diff-modified");
    let mut ctx = ImportContext::default();
    let mut from = empty_tree();
    let mut to = empty_tree();
    insert(&repository, &mut from, &mut ctx, "file.txt", b"first");
    insert(&repository, &mut to, &mut ctx, "file.txt", b"second");

    let changes = TreeDiff::run(&from, &to);

    assert_eq!(changes, vec![("file.txt".to_owned(), FileDiffKind::Modified)]);
}

#[test]
fn run_recurses_into_matched_subdirectories() {
    let (_scratch, repository) = open_repository("diff-nested");
    let mut ctx = ImportContext::default();
    let mut from = empty_tree();
    let mut to = empty_tree();
    FileHandle::new("dir")
        .insert_in_tree(&mut from, Stat::uninitialized())
        .unwrap();
    FileHandle::new("dir")
        .insert_in_tree(&mut to, Stat::uninitialized())
        .unwrap();
    insert(&repository, &mut to, &mut ctx, "dir/new.txt", b"content");

    let changes = TreeDiff::run(&from, &to);

    assert_eq!(changes, vec![("dir/new.txt".to_owned(), FileDiffKind::Added)]);
}

#[test]
fn run_marks_both_sides_when_a_directory_is_replaced_by_a_regular_file() {
    let (_scratch, repository) = open_repository("diff-type-change");
    let mut ctx = ImportContext::default();
    let mut from = empty_tree();
    let mut to = empty_tree();
    FileHandle::new("thing")
        .insert_in_tree(&mut from, Stat::uninitialized())
        .unwrap();
    insert(&repository, &mut from, &mut ctx, "thing/child", b"content");
    insert(&repository, &mut to, &mut ctx, "thing", b"content");

    let changes = TreeDiff::run(&from, &to);

    assert_eq!(changes.len(), 2);
    assert!(changes.contains(&("thing".to_owned(), FileDiffKind::Added)));
    assert!(changes.contains(&("thing/child".to_owned(), FileDiffKind::Removed)));
}

#[test]
fn run_ignores_a_bare_directory_present_on_only_one_side() {
    let (_scratch, repository) = open_repository("diff-dir-only-side");
    let mut ctx = ImportContext::default();
    let mut from = empty_tree();
    let mut to = empty_tree();
    FileHandle::new("empty-dir")
        .insert_in_tree(&mut to, Stat::uninitialized())
        .unwrap();
    insert(&repository, &mut from, &mut ctx, "file.txt", b"content");
    insert(&repository, &mut to, &mut ctx, "file.txt", b"content");

    let changes = TreeDiff::run(&from, &to);

    assert!(changes.is_empty());
}
