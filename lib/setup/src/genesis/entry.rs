// SPDX-FileCopyrightText: 2026 JustPav
// SPDX-FileCopyrightText: 2026 SmoothTeam
//
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

use std::fs::{File, copy, create_dir_all, write};
use std::io::Read;

use composefs::erofs::reader::erofs_to_filesystem;
use composefs::fsverity::FsVerityHashValue;
use composefs::repository::Repository;
use composefs::tree::FileSystem;

use upac::boot::write_boot_entry;
use upac::composefs::file::FileHandle;
use upac::composefs::repository::ObjectID;
use upac::layout::boot::{UPAC_UKI_FROM_SLOT, UPAC_UKI_TO_SLOT};
use upac::layout::boot_plugins::{BOOT_PLUGINS_DIR, MANIFEST_EXTENSION};
use upac::orchestrator::Context;
use upac::orchestrator::stage::{NoRollback, RollbackGuard, Stage, StageResult};
use upac::plugin::boot::resolve_boot_plugin;

use upac_abi::hook::{CancelToken, ProgressEventBuilder};

use super::ctx_get;

use crate::error::SetupError;
use crate::layout::genesis::{EFI_LINUX_DIR, ESP_FALLBACK_LOADER};
use crate::target::TargetSysroot;
use crate::types::{GenesisInput, PrefixDigest};

pub struct StageBootStage;

impl Stage<SetupError> for StageBootStage {
    fn run(
        &self, context: &mut Context, _cancel: &CancelToken, progress: ProgressEventBuilder,
    ) -> Result<(ProgressEventBuilder, StageResult, Box<dyn RollbackGuard>), SetupError> {
        let target = ctx_get!(context, TargetSysroot);
        let input = ctx_get!(context, GenesisInput);
        let prefix_digest = ctx_get!(context, PrefixDigest);

        let repository = target.repository();
        let prefix_digest_hex = prefix_digest.0.to_hex();

        let prefix_tree = Self::reopen_tree(repository, &prefix_digest_hex)?;

        let plugin = resolve_boot_plugin(BOOT_PLUGINS_DIR, MANIFEST_EXTENSION, input.boot_plugin.as_deref())?;

        let esp_mount_point = target.esp_mount_point().to_string_lossy().into_owned();
        plugin.install(&esp_mount_point)?;

        if let Some(candidate) = plugin.esp_loader_source() {
            let handle = FileHandle::new(candidate);
            if handle.stat_in_tree(&prefix_tree).is_ok() {
                let loader_bytes = handle.read_file(repository, &prefix_tree)?;

                let destination = target.esp_mount_point().join(ESP_FALLBACK_LOADER);
                if let Some(parent) = destination.parent() {
                    create_dir_all(parent)?;
                }

                write(&destination, &loader_bytes)?;
            }
        }

        let entry_name = write_boot_entry(
            repository,
            &prefix_tree,
            prefix_digest.0.clone(),
            &target.esp_mount_point(),
            &prefix_digest_hex,
        )?;

        // UKI-direct: genesis is the very first deploy, so `upac-from.efi` (the fallback slot)
        // has nothing real to hold yet — seed it with the exact same image `write_boot_entry` just
        // wrote to `upac-to.efi`. `up install`/`update` never do this: only genesis creates both
        // files and both Boot#### entries; every later deploy only ever touches `upac-to.efi`.
        if entry_name == UPAC_UKI_TO_SLOT {
            let efi_linux = target.esp_mount_point().join(EFI_LINUX_DIR);
            let to_path = efi_linux.join(format!("{UPAC_UKI_TO_SLOT}.efi"));
            let from_path = efi_linux.join(format!("{UPAC_UKI_FROM_SLOT}.efi"));
            copy(&to_path, &from_path)?;

            let geometry = (
                target.esp_partition_number(),
                target.esp_starting_lba(),
                target.esp_ending_lba(),
                target.esp_unique_partition_guid(),
            );

            // Manual mode (pre-existing partitions) has nowhere to read GPT geometry back from —
            // registering the two Boot#### entries is skipped there, same as the existing
            // "pre-registered once, out of scope of this pipeline" assumption everywhere else.
            if let (Some(partition_number), Some(starting_lba), Some(ending_lba), Some(unique_partition_guid)) =
                geometry
            {
                plugin.register_boot_slots(
                    partition_number,
                    starting_lba,
                    ending_lba,
                    unique_partition_guid.to_bytes_le(),
                    UPAC_UKI_TO_SLOT,
                    UPAC_UKI_FROM_SLOT,
                )?;
            }
        }

        plugin.set_one_shot(&entry_name)?;

        Ok((progress, StageResult::Advance, Box::new(NoRollback)))
    }
}

impl StageBootStage {
    fn reopen_tree(repository: &Repository<ObjectID>, digest: &str) -> Result<FileSystem<ObjectID>, SetupError> {
        let (image, _enable_verity) = repository.open_image(digest)?;

        let mut data = Vec::new();
        File::from(image).read_to_end(&mut data)?;

        Ok(erofs_to_filesystem(&data)?)
    }
}
