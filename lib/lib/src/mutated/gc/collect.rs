// SPDX-FileCopyrightText: 2026 JustPav
// SPDX-FileCopyrightText: 2026 SmoothTeam
//
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

use upac_abi::hook::CancelToken;
use upac_types::hook::ProgressEventBuilder;

use super::{CollectedRoots, DeployProgress, GcError};

use crate::database::record::DeployRecord;
use crate::deploy::Deploy;
use crate::errors::CommonError;
use crate::orchestrator::context::{Context, ctx_get, ctx_take};
use crate::orchestrator::stage::{NoRollback, RollbackGuard, Stage, StageResult};

pub struct CollectRootsStage;

impl Stage<GcError> for CollectRootsStage {
    fn run(
        &self, context: &mut Context, _cancel: &CancelToken, mut progress: ProgressEventBuilder,
    ) -> Result<(ProgressEventBuilder, StageResult, Box<dyn RollbackGuard>), GcError> {
        let mut deploy_progress = ctx_take!(context, DeployProgress);
        let mut roots = ctx_take!(context, CollectedRoots);

        let deploy = ctx_get!(context, Deploy);

        let prefix_digest = deploy_progress.pending.pop_front().ok_or(CommonError::MissingResult)?;

        let record = DeployRecord::read(&deploy.deploy(&prefix_digest))?;

        roots.push(record.prefix_digest);
        if !record.working_config.is_empty() {
            roots.push(record.working_config);
        }
        for entry in record.config_history {
            roots.push(entry.config_digest);
        }

        let remaining = deploy_progress.pending.len() as u64;
        let processed = deploy_progress.total - remaining;
        progress = progress
            .subject(prefix_digest)
            .progress(processed, deploy_progress.total);

        let stage_result = if deploy_progress.pending.is_empty() {
            StageResult::Advance
        } else {
            StageResult::Repeat
        };

        context.put(deploy_progress);
        context.put(roots);

        Ok((progress, stage_result, Box::new(NoRollback)))
    }
}
