// SPDX-FileCopyrightText: 2026 JustPav
// SPDX-FileCopyrightText: 2026 SmoothTeam
//
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

use upac_abi::hook::CancelToken;

use upac_types::hook::ProgressEventBuilder;

use super::{RequestedConfigDigest, RollbackError, TargetPrefixDigest};

use crate::database::record::DeployRecord;
use crate::deploy::Deploy;
use crate::orchestrator::context::{Context, ctx_get};
use crate::orchestrator::stage::{RollbackGuard, Stage, StageResult};

pub struct MergeStage;

impl Stage<RollbackError> for MergeStage {
    fn run(
        &self, context: &mut Context, _cancel: &CancelToken, progress: ProgressEventBuilder,
    ) -> Result<(ProgressEventBuilder, StageResult, Box<dyn RollbackGuard>), RollbackError> {
        let requested = ctx_get!(context, RequestedConfigDigest);
        let deploy = ctx_get!(context, Deploy);

        let (config_digest, prefix_digest) = DeployRecord::resolve_config_digest(deploy, Some(&requested))?;

        let record_dir = deploy.deploy(&prefix_digest);
        let mut record = DeployRecord::read(&record_dir)?;

        let mut written = Vec::new();
        if record.working_config != config_digest {
            record.working_config = config_digest;
            written.push(record.write(&record_dir)?);
        }

        context.put(TargetPrefixDigest(prefix_digest));

        Ok((progress, StageResult::Advance, Box::new(written)))
    }
}
