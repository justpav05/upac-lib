// SPDX-FileCopyrightText: 2026 JustPav
// SPDX-FileCopyrightText: 2026 SmoothTeam
//
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

use upac_abi::DiffFileSource;
use upac_abi::hook::CancelToken;

use upac_types::hook::ProgressEventBuilder;

use super::{DiffError, DiffSnapshot};

use crate::composefs::diff::TreeDiff;
use crate::composefs::file::FileHandle;
use crate::database::meta::MetaStore;
use crate::database::record::DeployRecord;
use crate::database::{InMemory, MemoryDatabase};
use crate::deploy::digest::current_prefix_digest;
use crate::deploy::{Deploy, DeployMode};
use crate::layout::database::DATABASE_PATH;
use crate::orchestrator::context::{Context, ctx_get};
use crate::orchestrator::stage::{NoRollback, RollbackGuard, Stage, StageResult};

use upac_types::{RequestedConfigDigestRange, RequestedPrefixDigestRange};

pub struct PreparingStage;

impl Stage<DiffError> for PreparingStage {
    fn run(
        &self, context: &mut Context, _cancel: &CancelToken, progress: ProgressEventBuilder,
    ) -> Result<(ProgressEventBuilder, StageResult, Box<dyn RollbackGuard>), DiffError> {
        let requested_prefix = ctx_get!(context, RequestedPrefixDigestRange);
        let requested_config = ctx_get!(context, RequestedConfigDigestRange);

        let from_prefix_digest = match &requested_prefix.from {
            Some(prefix_digest) => prefix_digest.clone(),
            None => current_prefix_digest()?,
        };
        let to_prefix_digest = match &requested_prefix.to {
            Some(prefix_digest) => prefix_digest.clone(),
            None => current_prefix_digest()?,
        };

        let deploy = Deploy::new(DeployMode::ReadOnly)?;
        let repository = deploy.open_repository()?;

        let from_tree = deploy.open_tree(&from_prefix_digest)?;
        let to_tree = deploy.open_tree(&to_prefix_digest)?;

        let mut changed_files: Vec<_> = TreeDiff::run(&from_tree, &to_tree)
            .into_iter()
            .map(|(path, kind)| (path, kind, DiffFileSource::Prefix))
            .collect();

        let from_record = DeployRecord::read(&deploy.deploy(&from_prefix_digest))?;
        let to_record = DeployRecord::read(&deploy.deploy(&to_prefix_digest))?;

        let from_config_digest = from_record
            .resolve_own_config_digest(requested_config.from.as_deref())
            .ok_or_else(|| DiffError::ConfigDigestNotFound(requested_config.from.clone().unwrap_or_default()))?;
        let to_config_digest = to_record
            .resolve_own_config_digest(requested_config.to.as_deref())
            .ok_or_else(|| DiffError::ConfigDigestNotFound(requested_config.to.clone().unwrap_or_default()))?;

        let from_config_tree = deploy.open_tree(&from_config_digest)?;
        let to_config_tree = deploy.open_tree(&to_config_digest)?;

        changed_files.extend(
            TreeDiff::run(&from_config_tree, &to_config_tree)
                .into_iter()
                .map(|(path, kind)| (path, kind, DiffFileSource::Config)),
        );

        let from_bytes = FileHandle::new(DATABASE_PATH).read_file(&repository, &from_tree)?;
        let from_database = MemoryDatabase::open_in_memory(from_bytes)?;
        let from_packages = from_database.list_packages_metas()?;

        let to_bytes = FileHandle::new(DATABASE_PATH).read_file(&repository, &to_tree)?;
        let to_database = MemoryDatabase::open_in_memory(to_bytes)?;
        let to_packages = to_database.list_packages_metas()?;

        context.put(DiffSnapshot {
            from_packages,
            to_packages,
            changed_files,
            from_database,
            to_database,
        });

        Ok((progress, StageResult::Advance, Box::new(NoRollback)))
    }
}
