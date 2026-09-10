// SPDX-FileCopyrightText: 2026 JustPav
// SPDX-FileCopyrightText: 2026 SmoothTeam
//
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

use upac_abi::hook::CancelToken;
use upac_abi::{DiffFileSource, FileDiffKind};

use upac_types::entry::{DiffFileEntryCommon, DiffPrefixFileEntry};
use upac_types::hook::ProgressEventBuilder;

use super::{DiffPrefixError, DiffPrefixSnapshot};

use crate::database::attribution::FileAttribute;
use crate::orchestrator::context::{Context, ctx_take};
use crate::orchestrator::stage::{NoRollback, RollbackGuard, Stage, StageResult};

pub struct ComparingStage;

impl Stage<DiffPrefixError> for ComparingStage {
    fn run(
        &self, context: &mut Context, _cancel: &CancelToken, progress: ProgressEventBuilder,
    ) -> Result<(ProgressEventBuilder, StageResult, Box<dyn RollbackGuard>), DiffPrefixError> {
        let snapshot = ctx_take!(context, DiffPrefixSnapshot);

        let mut entries = Vec::new();

        for (path, kind) in snapshot.changed {
            let database = match kind {
                FileDiffKind::Removed => &snapshot.from_database,
                FileDiffKind::Added | FileDiffKind::Modified => &snapshot.to_database,
            };

            if let Some(attribution) = database.attribute_file(&path)? {
                entries.push(DiffPrefixFileEntry {
                    common: DiffFileEntryCommon { path, kind },
                    source: DiffFileSource::Prefix,
                    package_name: attribution.package_meta.name,
                    is_user: attribution.file_entry.is_user,
                });
            }
        }

        context.put(entries);

        Ok((progress, StageResult::Advance, Box::new(NoRollback)))
    }
}
