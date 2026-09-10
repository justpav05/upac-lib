// SPDX-FileCopyrightText: 2026 JustPav
// SPDX-FileCopyrightText: 2026 SmoothTeam
//
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

use std::fs::{File, write};
use std::path::Path;

use composefs::fsverity::FsVerityHashValue;
use composefs::generic_tree::Stat;
use composefs::repository::ImportContext;

use upac_abi::hook::CancelToken;

use upac_types::TmpPath;
use upac_types::hook::ProgressEventBuilder;

use super::{ImportedState, InstallError, NewState};

use crate::composefs::error::RepoError;
use crate::composefs::file::FileHandle;
use crate::composefs::repository::commit_tree;
use crate::database::InMemory;
use crate::deploy::Deploy;
use crate::layout::database::{DATABASE_PATH, INSTALLER_SCRATCH_FILENAME};
use crate::orchestrator::context::{Context, ctx_get, ctx_take};
use crate::orchestrator::stage::{NoRollback, RollbackGuard, Stage, StageResult};

pub struct CommitTransactionStage;

impl Stage<InstallError> for CommitTransactionStage {
    fn run(
        &self, context: &mut Context, _cancel: &CancelToken, progress: ProgressEventBuilder,
    ) -> Result<(ProgressEventBuilder, StageResult, Box<dyn RollbackGuard>), InstallError> {
        let imported_state = ctx_take!(context, ImportedState);
        let mut imported_ctx = ctx_take!(context, ImportContext);

        let tmp_path = ctx_get!(context, TmpPath);
        let deploy = ctx_get!(context, Deploy);

        let repository = deploy.open_repository()?;
        let mut tree = imported_state.tree;

        let database_bytes = imported_state.database.into_bytes()?;
        let database_scratch_path = Path::new(tmp_path.as_ref()).join(INSTALLER_SCRATCH_FILENAME);

        write(&database_scratch_path, &database_bytes).map_err(RepoError::from)?;

        FileHandle::new(DATABASE_PATH).insert_file(
            &repository,
            &mut tree,
            &File::open(&database_scratch_path).map_err(RepoError::from)?,
            Stat::uninitialized(),
            &mut imported_ctx,
        )?;

        let digest = commit_tree(&repository, tree)?;

        context.put(NewState {
            prefix_digest: digest.to_hex(),
            config_defaults: imported_state.config_defaults,
        });

        Ok((progress, StageResult::Advance, Box::new(NoRollback)))
    }
}
