// SPDX-FileCopyrightText: 2026 JustPav
// SPDX-FileCopyrightText: 2026 SmoothTeam
//
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

use upac_abi::hook::CancelToken;

use upac_types::RequestedPrefixDigestRange;
use upac_types::hook::ProgressEventBuilder;

use super::{DiffPrefixError, DiffPrefixSnapshot};

use crate::composefs::diff::TreeDiff;
use crate::composefs::file::FileHandle;
use crate::database::InMemory;
use crate::database::MemoryDatabase;
use crate::deploy::digest::current_prefix_digest;
use crate::deploy::{Deploy, DeployMode};
use crate::layout::database::DATABASE_PATH;
use crate::orchestrator::context::{Context, ctx_get};
use crate::orchestrator::stage::{NoRollback, RollbackGuard, Stage, StageResult};

pub struct PreparingStage;

impl Stage<DiffPrefixError> for PreparingStage {
    fn run(
        &self, context: &mut Context, _cancel: &CancelToken, progress: ProgressEventBuilder,
    ) -> Result<(ProgressEventBuilder, StageResult, Box<dyn RollbackGuard>), DiffPrefixError> {
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
        let to_tree = deploy.open_tree(&to_prefix_digest)?;

        let changed = TreeDiff::run(&from_tree, &to_tree);

        let from_bytes = FileHandle::new(DATABASE_PATH).read_file(&repository, &from_tree)?;
        let from_database = MemoryDatabase::open_in_memory(from_bytes)?;

        let to_bytes = FileHandle::new(DATABASE_PATH).read_file(&repository, &to_tree)?;
        let to_database = MemoryDatabase::open_in_memory(to_bytes)?;

        context.put(DiffPrefixSnapshot {
            changed,
            from_database,
            to_database,
        });

        Ok((progress, StageResult::Advance, Box::new(NoRollback)))
    }
}
