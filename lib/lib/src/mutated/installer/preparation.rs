// SPDX-FileCopyrightText: 2026 JustPav
// SPDX-FileCopyrightText: 2026 SmoothTeam
//
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

use std::fs::remove_dir_all;
use std::path::PathBuf;

use upac_abi::error::ErrorKind;
use upac_abi::hook::CancelToken;

use upac_types::TmpPath;
use upac_types::hook::ProgressEventBuilder;

use super::{InstallError, InstallProgress, UnpackState};

use crate::errors::CommonError;
use crate::orchestrator::context::{Context, ctx_get, ctx_take};
use crate::orchestrator::stage::{RollbackGuard, Stage, StageResult};

pub struct PreparationStage;

struct UnpackedPackageDir(PathBuf);

impl Stage<InstallError> for PreparationStage {
    fn run(
        &self, context: &mut Context, cancel: &CancelToken, mut progress: ProgressEventBuilder,
    ) -> Result<(ProgressEventBuilder, StageResult, Box<dyn RollbackGuard>), InstallError> {
        let mut unpack_state = ctx_take!(context, UnpackState);
        let mut install_progress = ctx_take!(context, InstallProgress);

        let tmp_path = ctx_get!(context, TmpPath);

        let package_path = unpack_state
            .pending_paths
            .pop_front()
            .ok_or(CommonError::MissingResult)?;
        let index = install_progress.pending.len();

        let (package, trigger) = unpack_state
            .unpacker
            .unpack_one(&package_path, index, tmp_path.as_ref(), cancel)
            .map_err(CommonError::Decoder)?;

        let guard = UnpackedPackageDir(PathBuf::from(&package.temp_package_path));

        install_progress.pending.push_back((package, trigger));

        let remaining = unpack_state.pending_paths.len() as u64;
        let processed = install_progress.total - remaining;
        progress = progress
            .subject(package_path)
            .progress(processed, install_progress.total);

        let result = if unpack_state.pending_paths.is_empty() {
            StageResult::Advance
        } else {
            StageResult::Repeat
        };

        context.put(unpack_state);
        context.put(install_progress);

        Ok((progress, result, Box::new(guard)))
    }
}

impl RollbackGuard for UnpackedPackageDir {
    fn rollback(&mut self) -> Result<(), ErrorKind> {
        let _ = remove_dir_all(&self.0);

        Ok(())
    }
}
