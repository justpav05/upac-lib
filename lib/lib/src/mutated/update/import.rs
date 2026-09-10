// SPDX-FileCopyrightText: 2026 JustPav
// SPDX-FileCopyrightText: 2026 SmoothTeam
//
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

use std::path::Path;

use composefs::repository::ImportContext;

use upac_abi::hook::CancelToken;

use upac_types::entry::{FileEntry, FileEntryScope};
use upac_types::hook::ProgressEventBuilder;

use crate::composefs::file::{FileHandle, import_if_dir};
use crate::database::files::{FileStore, FileStoreMut};
use crate::database::meta::{MetaStore, MetaStoreMut};
use crate::database::triggers::TriggerStoreMut;
use crate::deploy::Deploy;
use crate::errors::CommonError;
use crate::mutated::update::{AllowDowngrade, ImportProgress, ImportedState, UpdateError};
use crate::orchestrator::context::{Context, ctx_get, ctx_take};
use crate::orchestrator::stage::{NoRollback, RollbackGuard, Stage, StageResult};

pub struct ImportPackageStage;

impl Stage<UpdateError> for ImportPackageStage {
    fn run(
        &self, context: &mut Context, cancel: &CancelToken, mut progress: ProgressEventBuilder,
    ) -> Result<(ProgressEventBuilder, StageResult, Box<dyn RollbackGuard>), UpdateError> {
        let mut import_progress = ctx_take!(context, ImportProgress);
        let mut imported_state = ctx_take!(context, ImportedState);
        let mut import_ctx = ctx_take!(context, ImportContext);

        let allow_downgrade = ctx_get!(context, AllowDowngrade);

        let deploy = ctx_get!(context, Deploy);

        let (package, trigger) = import_progress.pending.pop_front().ok_or(CommonError::MissingResult)?;

        let repository = deploy.open_repository()?;

        let uuid = imported_state
            .database
            .find_package_uuid(&package.meta.name, &package.meta.arch, package.meta.arch_sub.as_deref())?
            .ok_or(UpdateError::PackageNotFound)?;

        if !allow_downgrade.0 {
            let current_meta = imported_state
                .database
                .get_package_meta(uuid)?
                .ok_or(UpdateError::PackageNotFound)?;

            if package.meta.version < current_meta.version {
                return Err(UpdateError::DowngradeNotAllowed);
            }
        }

        let old_files = imported_state.database.list_package_files(uuid)?;

        for entry in old_files {
            match entry.scope {
                FileEntryScope::Prefix => {
                    FileHandle::new(&entry.path).remove_in_tree(&mut imported_state.tree)?;
                }
                FileEntryScope::Config => {
                    imported_state.removed_config_paths.push(entry.path.clone());
                }
            }

            imported_state.database.remove_package_file(uuid, &entry.path)?;
        }

        let source_root = Path::new(&package.temp_package_path);

        let usr_source = source_root.join("usr");
        let imported = import_if_dir!(
            &repository,
            &mut imported_state.tree,
            &usr_source,
            &mut import_ctx,
            cancel
        );

        let config_source = source_root.join("etc");
        let imported_config = import_if_dir!(
            &repository,
            &mut imported_state.config_defaults,
            &config_source,
            &mut import_ctx,
            cancel
        );

        imported_state.database.update_package_meta(&package.meta)?;
        imported_state.database.set_declarative_triggers(uuid, &trigger)?;

        for path in imported {
            imported_state.database.insert_package_file(
                uuid,
                &FileEntry {
                    path: path.to_string_lossy().into_owned(),
                    is_user: false,
                    scope: FileEntryScope::Prefix,
                },
            )?;
        }

        for path in imported_config {
            imported_state.database.insert_package_file(
                uuid,
                &FileEntry {
                    path: path.to_string_lossy().into_owned(),
                    is_user: false,
                    scope: FileEntryScope::Config,
                },
            )?;
        }

        let remaining = import_progress.pending.len() as u64;
        let processed = import_progress.total - remaining;
        progress = progress
            .subject(package.meta.name.clone())
            .progress(processed, import_progress.total);

        let result = if import_progress.pending.is_empty() {
            StageResult::Advance
        } else {
            StageResult::Repeat
        };

        context.put(import_progress);
        context.put(imported_state);
        context.put(import_ctx);

        Ok((progress, result, Box::new(NoRollback)))
    }
}
