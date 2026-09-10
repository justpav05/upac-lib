// SPDX-FileCopyrightText: 2026 JustPav
// SPDX-FileCopyrightText: 2026 SmoothTeam
//
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

use std::fs::{File, create_dir_all, write};
use std::path::Path;

use composefs::fsverity::FsVerityHashValue;
use composefs::generic_tree::Stat;
use composefs::repository::ImportContext;

use upac_abi::hook::CancelToken;

use upac_types::TmpPath;
use upac_types::hook::ProgressEventBuilder;

use super::{CommitInfo, FilesError, NewPrefixDigest, WorkingState};

use crate::composefs::error::RepoError;
use crate::composefs::file::FileHandle;
use crate::composefs::repository::commit_tree;
use crate::database::InMemory;
use crate::database::error::DeployRecordError;
use crate::database::record::DeployRecord;
use crate::deploy::Deploy;
use crate::deploy::digest::current_prefix_digest;
use crate::layout::database::{DATABASE_PATH, FILES_SCRATCH_FILENAME};
use crate::orchestrator::context::{Context, ctx_get, ctx_take};
use crate::orchestrator::stage::{RollbackGuard, Stage, StageResult};

pub struct CommitTransactionStage;

impl Stage<FilesError> for CommitTransactionStage {
    fn run(
        &self, context: &mut Context, _cancel: &CancelToken, progress: ProgressEventBuilder,
    ) -> Result<(ProgressEventBuilder, StageResult, Box<dyn RollbackGuard>), FilesError> {
        let working_state = ctx_take!(context, WorkingState);
        let mut imported_ctx = ctx_take!(context, ImportContext);

        let commit_info = ctx_get!(context, CommitInfo);
        let tmp_path = ctx_get!(context, TmpPath);

        let deploy = ctx_get!(context, Deploy);

        let repository = deploy.open_repository()?;
        let mut tree = working_state.tree;

        let database_bytes = working_state.database.into_bytes()?;
        let database_scratch_path = Path::new(tmp_path.as_ref()).join(FILES_SCRATCH_FILENAME);
        write(&database_scratch_path, &database_bytes).map_err(RepoError::from)?;

        FileHandle::new(DATABASE_PATH).insert_file(
            &repository,
            &mut tree,
            &File::open(&database_scratch_path).map_err(RepoError::from)?,
            Stat::uninitialized(),
            &mut imported_ctx,
        )?;

        let digest = commit_tree(&repository, tree)?;
        let new_prefix = digest.to_hex();

        let current_prefix = current_prefix_digest()?;
        let current_record_dir = deploy.deploy(&current_prefix);
        let current_record = DeployRecord::read(&current_record_dir)?;

        let new_record_dir = deploy.deploy(&new_prefix);
        let mut written = Vec::new();
        if DeployRecord::read(&new_record_dir).is_err() {
            create_dir_all(&new_record_dir).map_err(DeployRecordError::from)?;

            let record = DeployRecord {
                prefix_digest: new_prefix.clone(),
                subject: commit_info.subject.clone(),
                message: commit_info.message.clone(),
                seq: DeployRecord::allocate_seq(&deploy.next_seq_path())?,
                timestamp: DeployRecord::now_secs(),
                config_history: current_record.config_history.clone(),
                working_config: current_record.working_config.clone(),
                pinned: false,
            };
            written.push(record.write(&new_record_dir)?);
        }

        context.put(NewPrefixDigest(new_prefix));

        Ok((progress, StageResult::Advance, Box::new(written)))
    }
}
