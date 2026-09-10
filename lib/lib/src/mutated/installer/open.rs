// SPDX-FileCopyrightText: 2026 JustPav
// SPDX-FileCopyrightText: 2026 SmoothTeam
//
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

use composefs::generic_tree::Stat;
use composefs::repository::ImportContext;
use composefs::tree::FileSystem;

use upac_abi::hook::CancelToken;

use upac_types::hook::ProgressEventBuilder;

use super::{ImportedState, InstallError};

use crate::composefs::file::FileHandle;
use crate::database::{InMemory, MemoryDatabase};
use crate::deploy::Deploy;
use crate::deploy::digest::current_prefix_digest;
use crate::layout::database::DATABASE_PATH;
use crate::orchestrator::context::{Context, ctx_get};
use crate::orchestrator::stage::{NoRollback, RollbackGuard, Stage, StageResult};

pub struct OpenTransactionStage;

impl Stage<InstallError> for OpenTransactionStage {
    fn run(
        &self, context: &mut Context, _cancel: &CancelToken, progress: ProgressEventBuilder,
    ) -> Result<(ProgressEventBuilder, StageResult, Box<dyn RollbackGuard>), InstallError> {
        let deploy = ctx_get!(context, Deploy);

        let current_prefix = current_prefix_digest()?;
        let repository = deploy.open_repository()?;
        let tree = deploy.open_tree(&current_prefix)?;

        let database_bytes = FileHandle::new(DATABASE_PATH).read_file(&repository, &tree)?;
        let database = MemoryDatabase::open_in_memory(database_bytes)?;

        context.put(ImportedState {
            tree,
            config_defaults: FileSystem::new(Stat::uninitialized()),
            database,
        });
        context.put(ImportContext::default());

        Ok((progress, StageResult::Advance, Box::new(NoRollback)))
    }
}
