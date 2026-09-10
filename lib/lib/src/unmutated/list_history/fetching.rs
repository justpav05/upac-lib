// SPDX-FileCopyrightText: 2026 JustPav
// SPDX-FileCopyrightText: 2026 SmoothTeam
//
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

use upac_abi::hook::CancelToken;

use upac_types::entry::{ConfigCommitEntry, HistoryEntry};
use upac_types::hook::ProgressEventBuilder;

use super::ListHistoryError;

use crate::database::record::DeployRecord;
use crate::deploy::{Deploy, DeployMode};
use crate::orchestrator::context::Context;
use crate::orchestrator::stage::{NoRollback, RollbackGuard, Stage, StageResult};

pub struct FetchingStage;

impl Stage<ListHistoryError> for FetchingStage {
    fn run(
        &self, context: &mut Context, _cancel: &CancelToken, progress: ProgressEventBuilder,
    ) -> Result<(ProgressEventBuilder, StageResult, Box<dyn RollbackGuard>), ListHistoryError> {
        let deploy = Deploy::new(DeployMode::ReadOnly)?;

        let entries: Vec<HistoryEntry> = DeployRecord::read_all(&deploy)?
            .into_iter()
            .map(|record| HistoryEntry {
                prefix_digest: record.prefix_digest,
                subject: record.subject,
                message: record.message,
                timestamp: record.timestamp,
                working_config: Some(record.working_config),
                config_history: record
                    .config_history
                    .into_iter()
                    .map(|entry| ConfigCommitEntry {
                        config_digest: entry.config_digest,
                        subject: entry.subject,
                        message: entry.message,
                    })
                    .collect(),
            })
            .collect();

        context.put(entries);

        Ok((progress, StageResult::Advance, Box::new(NoRollback)))
    }
}
