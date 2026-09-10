// SPDX-FileCopyrightText: 2026 JustPav
// SPDX-FileCopyrightText: 2026 SmoothTeam
//
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

use upac_abi::hook::CancelToken;

use upac_types::hook::ProgressEventBuilder;

use super::{NewState, RequestedBootPlugin, ResolvedBootEntry, UninstallError};

use crate::boot::write_boot_entry;
use crate::composefs::repository::object_id_from_hex;
use crate::deploy::{Deploy, find_esp_mount};
use crate::orchestrator::context::{Context, ctx_get};
use crate::orchestrator::stage::{NoRollback, RollbackGuard, Stage, StageResult};
use crate::plugin::boot::BootPlugins;

pub struct CheckoutStage;

impl Stage<UninstallError> for CheckoutStage {
    fn run(
        &self, context: &mut Context, _cancel: &CancelToken, progress: ProgressEventBuilder,
    ) -> Result<(ProgressEventBuilder, StageResult, Box<dyn RollbackGuard>), UninstallError> {
        let new_state = ctx_get!(context, NewState);
        let deploy = ctx_get!(context, Deploy);
        let requested_boot_plugin = ctx_get!(context, RequestedBootPlugin);

        let repository = deploy.open_repository()?;
        let tree = deploy.open_tree(&new_state.prefix_digest)?;
        let digest = object_id_from_hex(&new_state.prefix_digest)?;

        let esp_mount = find_esp_mount()?;
        let entry_name = write_boot_entry(&repository, &tree, digest, &esp_mount, &new_state.prefix_digest)?;

        let plugin = BootPlugins::new()?.load(&requested_boot_plugin)?;

        context.put(ResolvedBootEntry { plugin, entry_name });

        Ok((progress, StageResult::Advance, Box::new(NoRollback)))
    }
}
