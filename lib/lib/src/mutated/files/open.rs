// SPDX-FileCopyrightText: 2026 JustPav
// SPDX-FileCopyrightText: 2026 SmoothTeam
//
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

use std::collections::VecDeque;

use composefs::repository::ImportContext;

use upac_abi::hook::CancelToken;
use upac_types::hook::ProgressEventBuilder;

use super::{ApplyTarget, FileProgress, FilesError, RequestedFilePackage, WorkingState};

use crate::composefs::file::FileHandle;
use crate::database::meta::MetaStore;
use crate::database::{InMemory, MemoryDatabase};
use crate::deploy::Deploy;
use crate::deploy::digest::current_prefix_digest;
use crate::layout::database::DATABASE_PATH;
use crate::layout::deployment::CONFIG_DIR_NAME;
use crate::orchestrator::context::{Context, ctx_get, ctx_take};
use crate::orchestrator::stage::{NoRollback, RollbackGuard, Stage, StageResult};

pub struct OpenTransactionStage;

impl Stage<FilesError> for OpenTransactionStage {
    fn run(
        &self, context: &mut Context, _cancel: &CancelToken, progress: ProgressEventBuilder,
    ) -> Result<(ProgressEventBuilder, StageResult, Box<dyn RollbackGuard>), FilesError> {
        let files = ctx_take!(context, Vec<String>);

        let file_package = ctx_get!(context, RequestedFilePackage);
        let deploy = ctx_get!(context, Deploy);

        let current_prefix = current_prefix_digest()?;
        let repository = deploy.open_repository()?;
        let tree = deploy.open_tree(&current_prefix)?;

        let current_record_dir = deploy.deploy(&current_prefix);
        let config_upper_dir = current_record_dir.join(CONFIG_DIR_NAME).join("upper");

        let database_bytes = FileHandle::new(DATABASE_PATH).read_file(&repository, &tree)?;
        let database = MemoryDatabase::open_in_memory(database_bytes)?;

        let uuid = database
            .find_package_uuid(&file_package.name, &file_package.arch, file_package.arch_sub.as_deref())?
            .ok_or(FilesError::PackageNotFound)?;

        let total = files.len() as u64;
        let pending: VecDeque<_> = files.into_iter().collect();

        context.put(WorkingState { tree, database });
        context.put(ImportContext::default());
        context.put(ApplyTarget { uuid, config_upper_dir });
        context.put(FileProgress { pending, total });

        Ok((progress, StageResult::Advance, Box::new(NoRollback)))
    }
}
