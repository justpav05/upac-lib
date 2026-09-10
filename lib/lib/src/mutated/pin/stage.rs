// SPDX-FileCopyrightText: 2026 JustPav
// SPDX-FileCopyrightText: 2026 SmoothTeam
//
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

use std::mem::replace;

use upac_abi::hook::CancelToken;

use upac_types::hook::ProgressEventBuilder;

use super::{PinError, RequestedPinned, RequestedPrefixDigest};

use crate::database::record::DeployRecord;
use crate::deploy::Deploy;
use crate::orchestrator::context::{Context, ctx_get};
use crate::orchestrator::stage::{RollbackGuard, Stage, StageResult};

pub struct SetPinnedStage;

impl Stage<PinError> for SetPinnedStage {
    fn run(
        &self, context: &mut Context, _cancel: &CancelToken, progress: ProgressEventBuilder,
    ) -> Result<(ProgressEventBuilder, StageResult, Box<dyn RollbackGuard>), PinError> {
        let deploy = ctx_get!(context, Deploy);
        let prefix_digest = ctx_get!(context, RequestedPrefixDigest);
        let pinned = ctx_get!(context, RequestedPinned);

        let record_dir = deploy.deploy(&prefix_digest);
        let mut record = DeployRecord::read(&record_dir)?;

        let mut written = Vec::new();
        if replace(&mut record.pinned, pinned.0) != record.pinned {
            written.push(record.write(&record_dir)?);
        }

        Ok((progress, StageResult::Advance, Box::new(written)))
    }
}
