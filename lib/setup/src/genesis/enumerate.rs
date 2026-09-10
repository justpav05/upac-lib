// SPDX-FileCopyrightText: 2026 JustPav
// SPDX-FileCopyrightText: 2026 SmoothTeam
//
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

use std::collections::VecDeque;
use std::fs::read_dir;

use composefs::generic_tree::Stat;
use composefs::repository::ImportContext;
use composefs::tree::FileSystem;

use tempfile::TempDir;

use upac::database::{InMemory, MemoryDatabase};
use upac::errors::CommonError;
use upac::orchestrator::Context;
use upac::orchestrator::stage::{NoRollback, RollbackGuard, Stage, StageResult};
use upac::plugin::decoder::unpack::PackageUnpacker;

use upac_abi::hook::{CancelToken, ProgressEventBuilder};

use upac_types::TmpPath;

use super::ctx_get;

use crate::error::SetupError;
use crate::types::{
    ConfigTree, GenesisDatabase, PendingPackagePaths, PendingPackages, PrefixTree, ResolvedSourceDir, TotalPackages,
    UnpackerState,
};

#[cfg(test)]
#[path = "../../tests/inline/enumerate.rs"]
mod tests;

pub struct EnumeratePackagesStage;

impl Stage<SetupError> for EnumeratePackagesStage {
    fn run(
        &self, context: &mut Context, _cancel: &CancelToken, progress: ProgressEventBuilder,
    ) -> Result<(ProgressEventBuilder, StageResult, Box<dyn RollbackGuard>), SetupError> {
        let resolved = ctx_get!(context, ResolvedSourceDir);

        let mut package_paths = Vec::new();
        for entry in read_dir(&resolved.0)? {
            let entry = entry?;

            if entry.metadata()?.is_file() {
                package_paths.push(entry.path().to_string_lossy().into_owned());
            }
        }

        let total = package_paths.len() as u64;

        let unpacker = PackageUnpacker::new().map_err(CommonError::Decoder)?;
        let scratch = TempDir::new()?;
        let tmp_path = TmpPath(scratch.path().to_string_lossy().into_owned());
        let database = MemoryDatabase::new_in_memory()?;

        context.put(PendingPackagePaths(VecDeque::from(package_paths)));
        context.put(TotalPackages(total));
        context.put(UnpackerState(unpacker));
        context.put(tmp_path);
        context.put(scratch);
        context.put(PendingPackages(VecDeque::new()));
        context.put(GenesisDatabase(database));
        context.put(PrefixTree(FileSystem::new(Stat::uninitialized())));
        context.put(ConfigTree(FileSystem::new(Stat::uninitialized())));
        context.put(ImportContext::default());

        Ok((progress, StageResult::Advance, Box::new(NoRollback)))
    }
}
