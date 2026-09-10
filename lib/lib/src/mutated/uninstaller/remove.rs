// SPDX-FileCopyrightText: 2026 JustPav
// SPDX-FileCopyrightText: 2026 SmoothTeam
//
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

use upac_abi::hook::CancelToken;

use upac_types::hook::ProgressEventBuilder;

use upac_types::entry::FileEntryScope;

use super::{Purge, RemoveProgress, UninstallError, WorkingState};

use crate::composefs::file::FileHandle;
use crate::database::files::{FileStore, FileStoreMut};
use crate::database::meta::{MetaStore, MetaStoreMut};
use crate::database::triggers::TriggerStoreMut;
use crate::errors::CommonError;
use crate::orchestrator::context::{Context, ctx_get, ctx_take};
use crate::orchestrator::stage::{NoRollback, RollbackGuard, Stage, StageResult};

pub struct RemovePackageStage;

impl Stage<UninstallError> for RemovePackageStage {
    fn run(
        &self, context: &mut Context, _cancel: &CancelToken, mut progress: ProgressEventBuilder,
    ) -> Result<(ProgressEventBuilder, StageResult, Box<dyn RollbackGuard>), UninstallError> {
        let mut woking_state = ctx_take!(context, WorkingState);
        let mut remove_progress = ctx_take!(context, RemoveProgress);

        let purge = ctx_get!(context, Purge);

        let uuid = remove_progress.pending.pop_front().ok_or(CommonError::MissingResult)?;

        let subject = woking_state
            .database
            .get_package_meta(uuid)?
            .map(|meta| meta.name)
            .unwrap_or_default();

        let files = woking_state.database.list_package_files(uuid)?;

        for entry in files {
            if entry.is_user && !purge.0 {
                continue;
            }

            match entry.scope {
                FileEntryScope::Prefix => {
                    FileHandle::new(&entry.path).remove_in_tree(&mut woking_state.tree)?;
                }
                FileEntryScope::Config => {
                    woking_state.removed_config_paths.push(entry.path.clone());
                }
            }

            if entry.is_user {
                woking_state.database.remove_user_file(uuid, &entry.path)?;
            } else {
                woking_state.database.remove_package_file(uuid, &entry.path)?;
            }
        }

        let meta = woking_state
            .database
            .get_package_meta(uuid)?
            .ok_or(UninstallError::PackageNotFound)?;
        woking_state
            .database
            .remove_package_meta(&meta.name, &meta.arch, meta.arch_sub.as_deref())?;
        woking_state.database.remove_declarative_triggers(uuid)?;

        let remaining = remove_progress.pending.len() as u64;
        let processed = remove_progress.total - remaining;
        progress = progress.subject(subject).progress(processed, remove_progress.total);

        let result = if remove_progress.pending.is_empty() {
            StageResult::Advance
        } else {
            StageResult::Repeat
        };

        context.put(remove_progress);
        context.put(woking_state);

        Ok((progress, result, Box::new(NoRollback)))
    }
}
