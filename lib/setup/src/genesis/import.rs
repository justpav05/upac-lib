// SPDX-FileCopyrightText: 2026 JustPav
// SPDX-FileCopyrightText: 2026 SmoothTeam
//
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

use std::path::Path;

use composefs::repository::ImportContext;

use upac::database::files::FileStoreMut;
use upac::database::meta::MetaStoreMut;
use upac::database::triggers::TriggerStoreMut;
use upac::errors::CommonError;
use upac::orchestrator::Context;
use upac::orchestrator::stage::{NoRollback, RollbackGuard, Stage, StageResult};

use upac_abi::hook::{CancelToken, ProgressEventBuilder};

use upac_types::{FileEntry, FileEntryScope};

use super::{ctx_get, ctx_take, import_if_dir};

use crate::error::SetupError;
use crate::target::TargetSysroot;
use crate::types::{ConfigTree, GenesisDatabase, GenesisInput, PendingPackages, PrefixTree, TotalPackages};

// No unit test: needs a real decoded package temp dir + a real composefs `Repository`, same
// untestable-in-isolation shape as `up install`'s own `ImportPackageStage` (lib/lib/src/mutated/installer).
pub struct ImportPackageStage;

impl Stage<SetupError> for ImportPackageStage {
    fn run(
        &self, context: &mut Context, cancel: &CancelToken, mut progress: ProgressEventBuilder,
    ) -> Result<(ProgressEventBuilder, StageResult, Box<dyn RollbackGuard>), SetupError> {
        let mut pending_packages = ctx_take!(context, PendingPackages);
        let mut prefix_tree = ctx_take!(context, PrefixTree);
        let mut config_tree = ctx_take!(context, ConfigTree);
        let mut database = ctx_take!(context, GenesisDatabase);
        let mut import_ctx = ctx_take!(context, ImportContext);

        let target = ctx_get!(context, TargetSysroot);
        let input = ctx_get!(context, GenesisInput);
        let total = ctx_get!(context, TotalPackages);

        let repository = target.repository();

        let (package, trigger) = pending_packages.0.pop_front().ok_or(CommonError::MissingResult)?;

        let source_root = Path::new(&package.temp_package_path);

        let prefix_source = source_root.join("usr");
        let imported = import_if_dir!(repository, &mut prefix_tree.0, &prefix_source, &mut import_ctx, cancel);

        let config_source = source_root.join("etc");
        let imported_config = if input.empty_config {
            Vec::new()
        } else {
            import_if_dir!(repository, &mut config_tree.0, &config_source, &mut import_ctx, cancel)
        };

        let uuid = database.0.insert_package_meta(&package.meta)?;
        database.0.set_declarative_triggers(uuid, &trigger)?;

        for path in imported {
            database.0.insert_package_file(
                uuid,
                &FileEntry {
                    path: path.to_string_lossy().into_owned(),
                    is_user: false,
                    scope: FileEntryScope::Prefix,
                },
            )?;
        }

        for path in imported_config {
            database.0.insert_package_file(
                uuid,
                &FileEntry {
                    path: path.to_string_lossy().into_owned(),
                    is_user: false,
                    scope: FileEntryScope::Config,
                },
            )?;
        }

        let remaining = pending_packages.0.len() as u64;
        let processed = total.0 - remaining;
        progress = progress.subject(package.meta.name.clone()).progress(processed, total.0);

        let result = if pending_packages.0.is_empty() {
            StageResult::Advance
        } else {
            StageResult::Repeat
        };

        context.put(pending_packages);
        context.put(prefix_tree);
        context.put(config_tree);
        context.put(database);
        context.put(import_ctx);

        Ok((progress, result, Box::new(NoRollback)))
    }
}
