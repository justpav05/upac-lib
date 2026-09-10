// SPDX-FileCopyrightText: 2026 JustPav
// SPDX-FileCopyrightText: 2026 SmoothTeam
//
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

use std::fs::{File, copy, create_dir_all, read_link, remove_file, symlink_metadata};
use std::os::unix::fs::symlink;
use std::path::Path;

use composefs::generic_tree::Stat;
use composefs::repository::{ImportContext, Repository};
use composefs::tree::FileSystem;

use upac_abi::hook::CancelToken;
use upac_abi::{DiffFileSource, FileDiffKind};

use upac_types::entry::{FileEntry, FileEntryScope};
use upac_types::hook::ProgressEventBuilder;

use super::{ApplyTarget, FileProgress, FilesError, RequestedFileOperation, WorkingState};

use crate::composefs::error::RepoError;
use crate::composefs::file::{FileHandle, stat_from_metadata};
use crate::composefs::repository::ObjectID;
use crate::database::files::FileStoreMut;
use crate::deploy::Deploy;
use crate::errors::CommonError;
use crate::layout::deployment::LIVE_ETC_DIR;
use crate::orchestrator::context::{Context, ctx_get, ctx_take};
use crate::orchestrator::stage::{NoRollback, RollbackGuard, Stage, StageResult};

pub struct ApplyFileStage;

impl Stage<FilesError> for ApplyFileStage {
    fn run(
        &self, context: &mut Context, _cancel: &CancelToken, mut progress: ProgressEventBuilder,
    ) -> Result<(ProgressEventBuilder, StageResult, Box<dyn RollbackGuard>), FilesError> {
        let mut file_progress = ctx_take!(context, FileProgress);
        let mut woking_state = ctx_take!(context, WorkingState);
        let mut imported_ctx = ctx_take!(context, ImportContext);

        let apply_target = ctx_get!(context, ApplyTarget);
        let file_operation = ctx_get!(context, RequestedFileOperation);

        let deploy = ctx_get!(context, Deploy);

        let path = file_progress.pending.pop_front().ok_or(CommonError::MissingResult)?;

        match file_operation.scope {
            DiffFileSource::Prefix => {
                let repository = deploy.open_repository()?;

                match file_operation.kind {
                    FileDiffKind::Removed => {
                        FileHandle::new(&path).remove_in_tree(&mut woking_state.tree)?;
                        woking_state.database.remove_user_file(apply_target.uuid, &path)?;
                    }
                    FileDiffKind::Added | FileDiffKind::Modified => {
                        Self::add_file(&path, &repository, &mut woking_state.tree, &mut imported_ctx)?;
                        woking_state.database.insert_package_file(
                            apply_target.uuid,
                            &FileEntry {
                                path: path.clone(),
                                is_user: true,
                                scope: FileEntryScope::Prefix,
                            },
                        )?;
                    }
                }
            }
            DiffFileSource::Config => match file_operation.kind {
                FileDiffKind::Removed => {
                    remove_file(apply_target.config_upper_dir.join(&path)).map_err(RepoError::from)?;
                    woking_state.database.remove_user_file(apply_target.uuid, &path)?;
                }
                FileDiffKind::Added | FileDiffKind::Modified => {
                    Self::add_config_file(&path, &apply_target.config_upper_dir)?;
                    woking_state.database.insert_package_file(
                        apply_target.uuid,
                        &FileEntry {
                            path: path.clone(),
                            is_user: true,
                            scope: FileEntryScope::Config,
                        },
                    )?;
                }
            },
        }

        let remaining = file_progress.pending.len() as u64;
        let processed = file_progress.total - remaining;
        progress = progress.subject(path).progress(processed, file_progress.total);

        let result = if file_progress.pending.is_empty() {
            StageResult::Advance
        } else {
            StageResult::Repeat
        };

        context.put(file_progress);
        context.put(woking_state);
        context.put(imported_ctx);

        Ok((progress, result, Box::new(NoRollback)))
    }
}

impl ApplyFileStage {
    fn add_file(
        path: &str, repository: &Repository<ObjectID>, tree: &mut FileSystem<ObjectID>,
        imported_ctx: &mut ImportContext,
    ) -> Result<(), FilesError> {
        let source_path = Path::new(path);
        let metadata = symlink_metadata(source_path).map_err(RepoError::from)?;
        let stat = stat_from_metadata(&metadata);
        let handle = FileHandle::new(path);

        let mut ancestors: Vec<&Path> = source_path
            .ancestors()
            .skip(1)
            .filter(|ancestor| !ancestor.as_os_str().is_empty())
            .collect();
        ancestors.reverse();

        for ancestor in ancestors {
            let ancestor_handle = FileHandle::new(ancestor);
            if ancestor_handle.stat_in_tree(tree).is_err() {
                ancestor_handle.insert_in_tree(tree, Stat::uninitialized())?;
            }
        }

        handle.remove_in_tree(tree)?;

        if metadata.is_symlink() {
            handle.symlink_in_tree(tree, read_link(source_path).map_err(RepoError::from)?, stat)?;
        } else {
            handle.insert_file(
                repository,
                tree,
                &File::open(source_path).map_err(RepoError::from)?,
                stat,
                imported_ctx,
            )?;
        }

        Ok(())
    }

    fn add_config_file(path: &str, config_upper_dir: &Path) -> Result<(), FilesError> {
        let live_path = Path::new(LIVE_ETC_DIR).join(path);
        let metadata = symlink_metadata(&live_path).map_err(RepoError::from)?;
        let dest_path = config_upper_dir.join(path);

        if let Some(parent) = dest_path.parent() {
            create_dir_all(parent).map_err(RepoError::from)?;
        }

        if metadata.is_symlink() {
            let _ = remove_file(&dest_path);
            symlink(read_link(&live_path).map_err(RepoError::from)?, &dest_path).map_err(RepoError::from)?;
        } else {
            copy(&live_path, &dest_path).map_err(RepoError::from)?;
        }

        Ok(())
    }
}
