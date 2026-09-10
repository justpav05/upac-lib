// SPDX-FileCopyrightText: 2026 JustPav
// SPDX-FileCopyrightText: 2026 SmoothTeam
//
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

use upac_abi::hook::CancelToken;

use upac_types::hook::ProgressEventBuilder;

use crate::mutated::update::UpdateError;
use crate::orchestrator::context::Context;
use crate::orchestrator::stage::{NoRollback, RollbackGuard, Stage, StageResult};

pub struct FetchingStage;

impl Stage<UpdateError> for FetchingStage {
    fn run(
        &self, _context: &mut Context, _cancel: &CancelToken, progress: ProgressEventBuilder,
    ) -> Result<(ProgressEventBuilder, StageResult, Box<dyn RollbackGuard>), UpdateError> {
        Ok((progress, StageResult::Advance, Box::new(NoRollback)))
    }
}
