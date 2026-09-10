// SPDX-FileCopyrightText: 2026 JustPav
// SPDX-FileCopyrightText: 2026 SmoothTeam
//
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

use upac_abi::hook::CancelToken;

use upac_types::hook::ProgressEventBuilder;

use super::ListPackagesError;

use crate::composefs::file::FileHandle;
use crate::database::meta::MetaStore;
use crate::database::{InMemory, MemoryDatabase};
use crate::deploy::digest::current_prefix_digest;
use crate::deploy::{Deploy, DeployMode};
use crate::layout::database::DATABASE_PATH;
use crate::orchestrator::context::Context;
use crate::orchestrator::stage::{NoRollback, RollbackGuard, Stage, StageResult};

pub struct FetchingStage;

impl Stage<ListPackagesError> for FetchingStage {
    fn run(
        &self, context: &mut Context, _cancel: &CancelToken, progress: ProgressEventBuilder,
    ) -> Result<(ProgressEventBuilder, StageResult, Box<dyn RollbackGuard>), ListPackagesError> {
        let prefix_digest = current_prefix_digest()?;

        let deploy = Deploy::new(DeployMode::ReadOnly)?;
        let repository = deploy.open_repository()?;
        let tree = deploy.open_tree(&prefix_digest)?;

        let database_bytes = FileHandle::new(DATABASE_PATH).read_file(&repository, &tree)?;
        let database = MemoryDatabase::open_in_memory(database_bytes)?;

        context.put(database.list_packages_metas()?);

        Ok((progress, StageResult::Advance, Box::new(NoRollback)))
    }
}
