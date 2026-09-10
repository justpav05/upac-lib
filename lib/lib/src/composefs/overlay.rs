// SPDX-FileCopyrightText: 2026 JustPav
// SPDX-FileCopyrightText: 2026 SmoothTeam
//
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

use std::fs::{File, Metadata, read_dir, read_link};
use std::os::unix::fs::{FileTypeExt, MetadataExt};
use std::path::{Path, PathBuf};

use composefs::repository::{ImportContext, Repository};
use composefs::tree::{FileSystem, Inode};

use super::error::RepoError;
use super::file::{FileHandle, stat_from_metadata};
use super::repository::ObjectID;

use crate::layout::deployment::OVERLAY_OPAQUE_XATTR;

pub fn apply_overlay_upper(
    repository: &Repository<ObjectID>, tree: &mut FileSystem<ObjectID>, upper_dir: &Path, ctx: &mut ImportContext,
) -> Result<(), RepoError> {
    fn recurse(
        repository: &Repository<ObjectID>, tree: &mut FileSystem<ObjectID>, tree_prefix: &Path, upper_dir: &Path,
        ctx: &mut ImportContext,
    ) -> Result<(), RepoError> {
        for entry in read_dir(upper_dir)? {
            let entry = entry?;
            let source_path = entry.path();
            let metadata = entry.metadata()?;
            let child_prefix = tree_prefix.join(entry.file_name());
            let child = FileHandle::new(&child_prefix);

            if is_whiteout(&metadata) {
                child.remove_in_tree(tree)?;
                continue;
            }

            let stat = stat_from_metadata(&metadata);

            if metadata.is_dir() {
                if is_opaque(&source_path)? || child.stat_in_tree(tree).is_err() {
                    child.remove_in_tree(tree)?;
                    child.insert_in_tree(tree, stat)?;
                } else {
                    child.update_in_tree(tree, stat)?;
                }

                recurse(repository, tree, &child_prefix, &source_path, ctx)?;
            } else if metadata.is_symlink() {
                child.remove_in_tree(tree)?;
                child.symlink_in_tree(tree, read_link(&source_path)?, stat)?;
            } else {
                child.remove_in_tree(tree)?;
                child.insert_file(repository, tree, &File::open(&source_path)?, stat, ctx)?;
            }
        }

        Ok(())
    }

    recurse(repository, tree, &PathBuf::new(), upper_dir, ctx)
}

pub fn apply_tree_overlay(base: &mut FileSystem<ObjectID>, overlay: &FileSystem<ObjectID>) -> Result<(), RepoError> {
    fn recurse(
        base: &mut FileSystem<ObjectID>, prefix: &Path, overlay: &FileSystem<ObjectID>,
    ) -> Result<(), RepoError> {
        for (name, inode) in FileHandle::new(prefix).list_in_tree(overlay)? {
            let child_prefix = prefix.join(name);
            let child = FileHandle::new(&child_prefix);

            match inode {
                Inode::Directory(directory) => {
                    if child.stat_in_tree(base).is_err() {
                        child.insert_in_tree(base, directory.stat.clone())?;
                    } else {
                        child.update_in_tree(base, directory.stat.clone())?;
                    }

                    recurse(base, &child_prefix, overlay)?;
                }
                Inode::Leaf(..) => {
                    child.remove_in_tree(base)?;
                    child.copy_from_tree(base, overlay, &child_prefix)?;
                }
            }
        }

        Ok(())
    }

    recurse(base, &PathBuf::new(), overlay)
}

fn is_whiteout(metadata: &Metadata) -> bool {
    metadata.file_type().is_char_device() && metadata.rdev() == 0
}

fn is_opaque(path: &Path) -> Result<bool, RepoError> {
    Ok(xattr::get(path, OVERLAY_OPAQUE_XATTR)?.as_deref() == Some(b"y"))
}
