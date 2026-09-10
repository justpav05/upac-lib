// SPDX-FileCopyrightText: 2026 JustPav
// SPDX-FileCopyrightText: 2026 SmoothTeam
//
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

use std::fs::create_dir_all;

use composefs::fsverity::FsVerityHashValue;
use composefs::repository::ImportContext;

use upac_abi::hook::CancelToken;

use upac_types::hook::ProgressEventBuilder;

use super::{AllowConflictFiles, CommitInfo, NewState, UpdateError};

use crate::composefs::file::FileHandle;
use crate::composefs::overlay::{apply_overlay_upper, apply_tree_overlay};
use crate::composefs::repository::commit_tree;
use crate::config::merge_config;
use crate::database::error::DeployRecordError;
use crate::database::record::DeployRecord;
use crate::deploy::Deploy;
use crate::deploy::digest::current_prefix_digest;
use crate::layout::deployment::CONFIG_DIR_NAME;
use crate::orchestrator::context::{Context, ctx_get};
use crate::orchestrator::stage::{RollbackGuard, Stage, StageResult};

pub struct MergeStage;

impl Stage<UpdateError> for MergeStage {
    fn run(
        &self, context: &mut Context, _cancel: &CancelToken, mut progress: ProgressEventBuilder,
    ) -> Result<(ProgressEventBuilder, StageResult, Box<dyn RollbackGuard>), UpdateError> {
        let new_state = ctx_get!(context, NewState);
        let deploy = ctx_get!(context, Deploy);
        let commit_info = ctx_get!(context, CommitInfo);
        let allow_conflict_files = ctx_get!(context, AllowConflictFiles);

        let repository = deploy.open_repository()?;

        let current_prefix = current_prefix_digest()?;
        let current_record_dir = deploy.deploy(&current_prefix);
        let current_record = DeployRecord::read(&current_record_dir)?;

        let base = deploy.open_tree(&current_record.working_config)?;

        let mut live = base.clone();
        let etc_upper_dir = current_record_dir.join(CONFIG_DIR_NAME).join("upper");
        let mut import_ctx = ImportContext::default();
        apply_overlay_upper(&repository, &mut live, &etc_upper_dir, &mut import_ctx)?;

        let mut new = base.clone();

        for path in &new_state.removed_config_paths {
            FileHandle::new(path).remove_in_tree(&mut new)?;
        }
        apply_tree_overlay(&mut new, &new_state.config_defaults)?;

        let merge_result = merge_config(&base, &new, &live, allow_conflict_files.0)?;
        let new_config_digest = commit_tree(&repository, merge_result.tree)?.to_hex();

        let conflicts_total = merge_result.conflicts.len() as u64;
        for (index, path) in merge_result.conflicts.iter().enumerate() {
            progress = progress.subject(path.clone()).progress(index as u64, conflicts_total);
            context.send_progress(&progress);
        }

        let new_record_dir = deploy.deploy(&new_state.prefix_digest);
        let mut record = match DeployRecord::read(&new_record_dir) {
            Ok(existing) => existing,
            Err(DeployRecordError::NotFound) => {
                create_dir_all(&new_record_dir).map_err(DeployRecordError::from)?;

                DeployRecord {
                    prefix_digest: new_state.prefix_digest.clone(),
                    subject: commit_info.subject.clone(),
                    message: commit_info.message.clone(),
                    seq: DeployRecord::allocate_seq(&deploy.next_seq_path())?,
                    timestamp: DeployRecord::now_secs(),
                    config_history: Vec::new(),
                    working_config: String::new(),
                    pinned: false,
                }
            }
            Err(error) => return Err(error.into()),
        };

        let mut written = Vec::new();
        written.extend(record.update_working_config(
            &new_record_dir,
            new_config_digest,
            commit_info.subject.clone(),
            commit_info.message.clone(),
        )?);

        Ok((progress, StageResult::Advance, Box::new(written)))
    }
}
