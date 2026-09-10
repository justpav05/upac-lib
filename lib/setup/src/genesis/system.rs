// SPDX-FileCopyrightText: 2026 JustPav
// SPDX-FileCopyrightText: 2026 SmoothTeam
//
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

use std::path::Path;

use composefs::generic_tree::Stat;
use composefs::repository::ImportContext;
use composefs::tree::FileSystem;

use upac::composefs::file::FileHandle;
use upac::composefs::repository::ObjectID;
use upac::orchestrator::Context;
use upac::orchestrator::stage::{NoRollback, RollbackGuard, Stage, StageResult};

use upac_abi::hook::{CancelToken, ProgressEventBuilder};

use super::{ctx_get, ctx_take, import_if_dir};

use crate::error::SetupError;
use crate::layout::genesis::{
    COMPOSEFS_SETUP_ROOT_UNIT_PATH, COMPOSEFS_SETUP_ROOT_WANTS_PATH, COMPOSEFS_SETUP_ROOT_WANTS_TARGET, SYSTEM_DIR,
};
use crate::target::TargetSysroot;
use crate::types::{PrefixTree, ResolvedSourceDir};

// No unit test: needs a real filesystem tree to import + a real composefs `Repository`, same
// untestable-in-isolation shape as `ImportPackageStage`.
pub struct ImportSystemStage;

impl Stage<SetupError> for ImportSystemStage {
    fn run(
        &self, context: &mut Context, cancel: &CancelToken, progress: ProgressEventBuilder,
    ) -> Result<(ProgressEventBuilder, StageResult, Box<dyn RollbackGuard>), SetupError> {
        let mut prefix_tree = ctx_take!(context, PrefixTree);
        let mut import_ctx = ctx_take!(context, ImportContext);

        let resolved = ctx_get!(context, ResolvedSourceDir);
        let target = ctx_get!(context, TargetSysroot);

        let repository = target.repository();

        let system_dir = resolved.0.join(SYSTEM_DIR);
        let unit_source = system_dir.join(COMPOSEFS_SETUP_ROOT_UNIT_PATH);
        if !unit_source.is_file() {
            return Err(SetupError::ComposefsSetupRootUnitNotFound);
        }

        import_if_dir!(repository, &mut prefix_tree.0, &system_dir, &mut import_ctx, cancel);

        ensure_ancestor_dirs(COMPOSEFS_SETUP_ROOT_WANTS_PATH, &mut prefix_tree.0)?;
        FileHandle::new(COMPOSEFS_SETUP_ROOT_WANTS_PATH).symlink_in_tree(
            &mut prefix_tree.0,
            COMPOSEFS_SETUP_ROOT_WANTS_TARGET,
            Stat::uninitialized(),
        )?;

        context.put(prefix_tree);
        context.put(import_ctx);

        Ok((progress, StageResult::Advance, Box::new(NoRollback)))
    }
}

fn ensure_ancestor_dirs(path: &str, tree: &mut FileSystem<ObjectID>) -> Result<(), SetupError> {
    let mut ancestors: Vec<&Path> = Path::new(path)
        .ancestors()
        .skip(1)
        .filter(|ancestor| !ancestor.as_os_str().is_empty())
        .collect();
    ancestors.reverse();

    for ancestor in ancestors {
        let handle = FileHandle::new(ancestor);
        if handle.stat_in_tree(tree).is_err() {
            handle.insert_in_tree(tree, Stat::uninitialized())?;
        }
    }

    Ok(())
}
