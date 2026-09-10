// SPDX-FileCopyrightText: 2026 JustPav
// SPDX-FileCopyrightText: 2026 SmoothTeam
//
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

use upac_abi::hook::CancelToken;

use upac_types::hook::ProgressEventBuilder;
use upac_types::request::BootPluginSetOneShotRequest;

use super::{InstallError, ResolvedBootEntry};

use crate::orchestrator::context::{Context, ctx_take};
use crate::orchestrator::stage::{NoRollback, RollbackGuard, Stage, StageResult};

pub struct SwapStage;

impl Stage<InstallError> for SwapStage {
    fn run(
        &self, context: &mut Context, _cancel: &CancelToken, progress: ProgressEventBuilder,
    ) -> Result<(ProgressEventBuilder, StageResult, Box<dyn RollbackGuard>), InstallError> {
        let resolved = ctx_take!(context, ResolvedBootEntry);

        resolved.plugin.set_one_shot(BootPluginSetOneShotRequest {
            entry_name: resolved.entry_name,
        })?;

        Ok((progress, StageResult::Advance, Box::new(NoRollback)))
    }
}
