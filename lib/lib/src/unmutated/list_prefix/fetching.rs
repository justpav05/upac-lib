// SPDX-FileCopyrightText: 2026 JustPav
// SPDX-FileCopyrightText: 2026 SmoothTeam
//
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

use upac_abi::hook::CancelToken;

use upac_types::entry::PrefixEntry;
use upac_types::hook::ProgressEventBuilder;

use super::ListPrefixError;

use crate::database::record::DeployRecord;
use crate::deploy::{Deploy, DeployMode};
use crate::orchestrator::context::Context;
use crate::orchestrator::stage::{NoRollback, RollbackGuard, Stage, StageResult};

pub struct FetchingStage;

impl Stage<ListPrefixError> for FetchingStage {
    fn run(
        &self, context: &mut Context, _cancel: &CancelToken, progress: ProgressEventBuilder,
    ) -> Result<(ProgressEventBuilder, StageResult, Box<dyn RollbackGuard>), ListPrefixError> {
        let deploy = Deploy::new(DeployMode::ReadOnly)?;

        let entries: Vec<PrefixEntry> = DeployRecord::read_all(&deploy)?
            .into_iter()
            .map(|record| PrefixEntry {
                prefix_digest: record.prefix_digest,
                subject: record.subject,
                message: record.message,
                timestamp: record.timestamp,
                working_config: Some(record.working_config),
            })
            .collect();

        context.put(entries);

        Ok((progress, StageResult::Advance, Box::new(NoRollback)))
    }
}
