// SPDX-FileCopyrightText: 2026 JustPav
// SPDX-FileCopyrightText: 2026 SmoothTeam
//
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

use upac_abi::hook::CancelToken;

use upac_types::RequestedPrefixDigest;
use upac_types::entry::ConfigCommitEntry;
use upac_types::hook::ProgressEventBuilder;

use super::ListConfigError;

use crate::database::record::DeployRecord;
use crate::deploy::digest::current_prefix_digest;
use crate::deploy::{Deploy, DeployMode};
use crate::orchestrator::context::{Context, ctx_get};
use crate::orchestrator::stage::{NoRollback, RollbackGuard, Stage, StageResult};

pub struct FetchingStage;

impl Stage<ListConfigError> for FetchingStage {
    fn run(
        &self, context: &mut Context, _cancel: &CancelToken, progress: ProgressEventBuilder,
    ) -> Result<(ProgressEventBuilder, StageResult, Box<dyn RollbackGuard>), ListConfigError> {
        let requested = ctx_get!(context, RequestedPrefixDigest);

        let prefix_digest = match &requested.0 {
            Some(prefix_digest) => prefix_digest.clone(),
            None => current_prefix_digest()?,
        };

        let deploy = Deploy::new(DeployMode::ReadOnly)?;
        let record = DeployRecord::read(&deploy.deploy(&prefix_digest))?;

        let entries: Vec<ConfigCommitEntry> = record
            .config_history
            .into_iter()
            .map(|entry| ConfigCommitEntry {
                config_digest: entry.config_digest,
                subject: entry.subject,
                message: entry.message,
            })
            .collect();

        context.put(entries);

        Ok((progress, StageResult::Advance, Box::new(NoRollback)))
    }
}
