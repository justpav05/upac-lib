// SPDX-FileCopyrightText: 2026 JustPav
// SPDX-FileCopyrightText: 2026 SmoothTeam
//
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

use upac::errors::CommonError;
use upac::orchestrator::Context;
use upac::orchestrator::stage::{NoRollback, RollbackGuard, Stage, StageResult};

use upac_abi::hook::{CancelToken, ProgressEventBuilder};

use upac_types::TmpPath;

use super::{ctx_get, ctx_take};

use crate::error::SetupError;
use crate::types::{PendingPackagePaths, PendingPackages, TotalPackages, UnpackerState};

// No unit test: needs a real decoder + a real package archive to unpack, same untestable-in-
// isolation shape as `up install`'s own `PreparationStage` (lib/lib/src/mutated/installer).
pub struct UnpackPackageStage;

impl Stage<SetupError> for UnpackPackageStage {
    fn run(
        &self, context: &mut Context, cancel: &CancelToken, mut progress: ProgressEventBuilder,
    ) -> Result<(ProgressEventBuilder, StageResult, Box<dyn RollbackGuard>), SetupError> {
        let mut pending_paths = ctx_take!(context, PendingPackagePaths);
        let mut unpacker = ctx_take!(context, UnpackerState);
        let mut pending_packages = ctx_take!(context, PendingPackages);

        let tmp_path = ctx_get!(context, TmpPath);
        let total = ctx_get!(context, TotalPackages);

        let package_path = pending_paths.0.pop_front().ok_or(CommonError::MissingResult)?;
        let index = pending_packages.0.len();

        let (package, trigger) = unpacker
            .0
            .unpack_one(&package_path, index, tmp_path.as_ref(), cancel)
            .map_err(CommonError::Decoder)?;

        pending_packages.0.push_back((package, trigger));

        let remaining = pending_paths.0.len() as u64;
        let processed = total.0 - remaining;
        progress = progress.subject(package_path).progress(processed, total.0);

        let result = if pending_paths.0.is_empty() {
            StageResult::Advance
        } else {
            StageResult::Repeat
        };

        context.put(pending_paths);
        context.put(unpacker);
        context.put(pending_packages);

        Ok((progress, result, Box::new(NoRollback)))
    }
}
