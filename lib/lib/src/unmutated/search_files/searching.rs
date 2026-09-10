// SPDX-FileCopyrightText: 2026 JustPav
// SPDX-FileCopyrightText: 2026 SmoothTeam
//
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

use upac_abi::hook::CancelToken;

use upac_types::entry::SearchFileEntry;
use upac_types::hook::ProgressEventBuilder;

use super::SearchFilesError;

use crate::composefs::file::FileHandle;
use crate::database::files::FileStore;
use crate::database::meta::MetaStore;
use crate::database::{InMemory, MemoryDatabase};
use crate::deploy::digest::current_prefix_digest;
use crate::deploy::{Deploy, DeployMode};
use crate::layout::database::DATABASE_PATH;
use crate::orchestrator::context::{Context, ctx_get};
use crate::orchestrator::stage::{NoRollback, RollbackGuard, Stage, StageResult};
use crate::search::Search;

pub struct SearchingStage;

impl Stage<SearchFilesError> for SearchingStage {
    fn run(
        &self, context: &mut Context, _cancel: &CancelToken, progress: ProgressEventBuilder,
    ) -> Result<(ProgressEventBuilder, StageResult, Box<dyn RollbackGuard>), SearchFilesError> {
        let search = ctx_get!(context, Search);

        let prefix_digest = current_prefix_digest()?;

        let deploy = Deploy::new(DeployMode::ReadOnly)?;
        let repository = deploy.open_repository()?;

        let tree = deploy.open_tree(&prefix_digest)?;

        let database_bytes = FileHandle::new(DATABASE_PATH).read_file(&repository, &tree)?;
        let database = MemoryDatabase::open_in_memory(database_bytes)?;

        let mut matches = Vec::new();

        for (uuid, file_entry) in database.list_files()? {
            if !search.is_match(&file_entry.path) {
                continue;
            }

            let Some(package_meta) = database.get_package_meta(uuid)? else {
                continue;
            };

            matches.push(SearchFileEntry {
                path: file_entry.path,
                package_name: package_meta.name,
                is_user: file_entry.is_user,
            });
        }

        context.put(matches);

        Ok((progress, StageResult::Advance, Box::new(NoRollback)))
    }
}
