// SPDX-FileCopyrightText: 2026 JustPav
// SPDX-FileCopyrightText: 2026 SmoothTeam
//
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

use upac_abi::hook::CancelToken;

use upac_types::hook::ProgressEventBuilder;

use super::{DiffConfigError, DiffConfigSnapshot};

use crate::composefs::diff::TreeDiff;
use crate::composefs::file::FileHandle;
use crate::database::record::DeployRecord;
use crate::database::{InMemory, MemoryDatabase};
use crate::deploy::{Deploy, DeployMode};
use crate::layout::database::DATABASE_PATH;
use crate::orchestrator::context::{Context, ctx_get};
use crate::orchestrator::stage::{NoRollback, RollbackGuard, Stage, StageResult};

use upac_types::RequestedConfigDigestRange;

pub struct PreparingStage;

impl Stage<DiffConfigError> for PreparingStage {
    fn run(
        &self, context: &mut Context, _cancel: &CancelToken, progress: ProgressEventBuilder,
    ) -> Result<(ProgressEventBuilder, StageResult, Box<dyn RollbackGuard>), DiffConfigError> {
        let requested = ctx_get!(context, RequestedConfigDigestRange);

        let deploy = Deploy::new(DeployMode::ReadOnly)?;

        let (from_config_digest, from_prefix_digest) =
            DeployRecord::resolve_config_digest(&deploy, requested.from.as_deref())?;
        let (to_config_digest, to_prefix_digest) =
            DeployRecord::resolve_config_digest(&deploy, requested.to.as_deref())?;

        let repository = deploy.open_repository()?;

        let from_config_tree = deploy.open_tree(&from_config_digest)?;
        let to_config_tree = deploy.open_tree(&to_config_digest)?;

        let changed = TreeDiff::run(&from_config_tree, &to_config_tree);

        let from_prefix_tree = deploy.open_tree(&from_prefix_digest)?;
        let from_bytes = FileHandle::new(DATABASE_PATH).read_file(&repository, &from_prefix_tree)?;
        let from_database = MemoryDatabase::open_in_memory(from_bytes)?;

        let to_prefix_tree = deploy.open_tree(&to_prefix_digest)?;
        let to_bytes = FileHandle::new(DATABASE_PATH).read_file(&repository, &to_prefix_tree)?;
        let to_database = MemoryDatabase::open_in_memory(to_bytes)?;

        context.put(DiffConfigSnapshot {
            changed,
            from_database,
            to_database,
        });

        Ok((progress, StageResult::Advance, Box::new(NoRollback)))
    }
}
