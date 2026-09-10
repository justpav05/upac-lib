// SPDX-FileCopyrightText: 2026 JustPav
// SPDX-FileCopyrightText: 2026 SmoothTeam
//
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

use upac_abi::hook::CancelToken;

use upac_types::hook::ProgressEventBuilder;
use upac_types::{DiffPackagesSnapshot, RequestedPrefixDigestRange};

use super::DiffPackagesError;

use crate::composefs::file::FileHandle;
use crate::database::meta::MetaStore;
use crate::database::{InMemory, MemoryDatabase};
use crate::deploy::digest::current_prefix_digest;
use crate::deploy::{Deploy, DeployMode};
use crate::layout::database::DATABASE_PATH;
use crate::orchestrator::context::{Context, ctx_get};
use crate::orchestrator::stage::{NoRollback, RollbackGuard, Stage, StageResult};

pub struct PreparingStage;

impl Stage<DiffPackagesError> for PreparingStage {
    fn run(
        &self, context: &mut Context, _cancel: &CancelToken, progress: ProgressEventBuilder,
    ) -> Result<(ProgressEventBuilder, StageResult, Box<dyn RollbackGuard>), DiffPackagesError> {
        let requested = ctx_get!(context, RequestedPrefixDigestRange);

        let from_prefix_digest = match &requested.from {
            Some(prefix_digest) => prefix_digest.clone(),
            None => current_prefix_digest()?,
        };
        let to_prefix_digest = match &requested.to {
            Some(prefix_digest) => prefix_digest.clone(),
            None => current_prefix_digest()?,
        };

        let deploy = Deploy::new(DeployMode::ReadOnly)?;
        let repository = deploy.open_repository()?;

        let from_tree = deploy.open_tree(&from_prefix_digest)?;
        let from_bytes = FileHandle::new(DATABASE_PATH).read_file(&repository, &from_tree)?;
        let from = MemoryDatabase::open_in_memory(from_bytes)?.list_packages_metas()?;

        let to_tree = deploy.open_tree(&to_prefix_digest)?;
        let to_bytes = FileHandle::new(DATABASE_PATH).read_file(&repository, &to_tree)?;
        let to = MemoryDatabase::open_in_memory(to_bytes)?.list_packages_metas()?;

        context.put(DiffPackagesSnapshot { from, to });

        Ok((progress, StageResult::Advance, Box::new(NoRollback)))
    }
}
