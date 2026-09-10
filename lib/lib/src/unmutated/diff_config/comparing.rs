// SPDX-FileCopyrightText: 2026 JustPav
// SPDX-FileCopyrightText: 2026 SmoothTeam
//
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

use upac_abi::FileDiffKind;
use upac_abi::hook::CancelToken;

use upac_types::hook::ProgressEventBuilder;

use super::{DiffConfigError, DiffConfigSnapshot};

use crate::database::attribution::FileAttribute;
use crate::orchestrator::context::{Context, ctx_take};
use crate::orchestrator::stage::{NoRollback, RollbackGuard, Stage, StageResult};

use upac_types::entry::{DiffConfigFileEntry, DiffFileEntryCommon};

pub struct ComparingStage;

impl Stage<DiffConfigError> for ComparingStage {
    fn run(
        &self, context: &mut Context, _cancel: &CancelToken, progress: ProgressEventBuilder,
    ) -> Result<(ProgressEventBuilder, StageResult, Box<dyn RollbackGuard>), DiffConfigError> {
        let snapshot = ctx_take!(context, DiffConfigSnapshot);

        let mut entries = Vec::new();

        for (path, kind) in snapshot.changed {
            let database = match kind {
                FileDiffKind::Removed => &snapshot.from_database,
                FileDiffKind::Added | FileDiffKind::Modified => &snapshot.to_database,
            };

            let package_name = database
                .attribute_file(&path)?
                .map(|attribution| attribution.package_meta.name);

            entries.push(DiffConfigFileEntry {
                common: DiffFileEntryCommon { path, kind },
                package_name,
            });
        }

        context.put(entries);

        Ok((progress, StageResult::Advance, Box::new(NoRollback)))
    }
}
