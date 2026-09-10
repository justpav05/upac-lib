// SPDX-FileCopyrightText: 2026 JustPav
// SPDX-FileCopyrightText: 2026 SmoothTeam
//
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

use std::collections::BTreeMap;
use std::path::Path;

use composefs::tree::FileSystem;

use upac_abi::FileDiffKind;

use crate::composefs::diff::TreeDiff;
use crate::composefs::error::RepoError;
use crate::composefs::file::FileHandle;
use crate::composefs::repository::ObjectID;

pub struct MergeResult {
    pub tree: FileSystem<ObjectID>,
    pub conflicts: Vec<String>,
}

pub fn merge_config(
    base: &FileSystem<ObjectID>, new: &FileSystem<ObjectID>, live: &FileSystem<ObjectID>, allow_conflict_files: bool,
) -> Result<MergeResult, RepoError> {
    let user_changes = TreeDiff::run(base, live);
    let package_changes: BTreeMap<String, FileDiffKind> = TreeDiff::run(base, new).into_iter().collect();

    let mut tree = new.clone();
    let mut conflicts = Vec::new();

    for (path, kind) in user_changes {
        let package_change = package_changes.get(&path);

        match kind {
            FileDiffKind::Removed => match package_change {
                Some(FileDiffKind::Added | FileDiffKind::Modified) => conflicts.push(path),
                Some(FileDiffKind::Removed) => {}
                None => FileHandle::new(&path).remove_in_tree(&mut tree)?,
            },
            FileDiffKind::Added | FileDiffKind::Modified => {
                if let Some(FileDiffKind::Added | FileDiffKind::Modified) = package_change {
                    if allow_conflict_files {
                        FileHandle::new(format!("{path}.upac-new")).copy_from_tree(&mut tree, new, Path::new(&path))?;
                    }
                    conflicts.push(path.clone());
                }

                FileHandle::new(&path).copy_from_tree(&mut tree, live, Path::new(&path))?;
            }
        }
    }

    Ok(MergeResult { tree, conflicts })
}
