// SPDX-FileCopyrightText: 2026 JustPav
// SPDX-FileCopyrightText: 2026 SmoothTeam
//
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

use std::path::Path;

use composefs::repository::ImportContext;

use upac_abi::hook::CancelToken;

use upac_types::entry::{FileEntry, FileEntryScope};
use upac_types::hook::ProgressEventBuilder;

use super::{ImportedState, InstallError, InstallProgress};

use crate::composefs::file::import_if_dir;
use crate::database::files::FileStoreMut;
use crate::database::meta::MetaStoreMut;
use crate::database::triggers::TriggerStoreMut;
use crate::deploy::Deploy;
use crate::errors::CommonError;
use crate::orchestrator::context::{Context, ctx_get, ctx_take};
use crate::orchestrator::stage::{NoRollback, RollbackGuard, Stage, StageResult};

pub struct ImportPackageStage;

impl Stage<InstallError> for ImportPackageStage {
    fn run(
        &self, context: &mut Context, cancel: &CancelToken, mut progress: ProgressEventBuilder,
    ) -> Result<(ProgressEventBuilder, StageResult, Box<dyn RollbackGuard>), InstallError> {
        let mut install_progress = ctx_take!(context, InstallProgress);
        let mut imported_state = ctx_take!(context, ImportedState);
        let mut imported_ctx = ctx_take!(context, ImportContext);

        let deploy = ctx_get!(context, Deploy);

        let (package, trigger) = install_progress.pending.pop_front().ok_or(CommonError::MissingResult)?;

        let repository = deploy.open_repository()?;
        let source_root = Path::new(&package.temp_package_path);

        let prefix_source = source_root.join("usr");
        let imported = import_if_dir!(
            &repository,
            &mut imported_state.tree,
            &prefix_source,
            &mut imported_ctx,
            cancel
        );

        let config_source = source_root.join("etc");
        let imported_config = import_if_dir!(
            &repository,
            &mut imported_state.config_defaults,
            &config_source,
            &mut imported_ctx,
            cancel
        );

        let uuid = imported_state.database.insert_package_meta(&package.meta)?;
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

        let remaining = install_progress.pending.len() as u64;
        let processed = install_progress.total - remaining;
        progress = progress
            .subject(package.meta.name.clone())
            .progress(processed, install_progress.total);

        let stage_result = if install_progress.pending.is_empty() {
            StageResult::Advance
        } else {
            StageResult::Repeat
        };

        context.put(install_progress);
        context.put(imported_state);
        context.put(imported_ctx);

        Ok((progress, stage_result, Box::new(NoRollback)))
    }
}
