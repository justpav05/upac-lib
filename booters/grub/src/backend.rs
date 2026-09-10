// SPDX-FileCopyrightText: 2026 JustPav
// SPDX-FileCopyrightText: 2026 SmoothTeam
//
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

use std::fs::{create_dir_all, write};
use std::io::ErrorKind as IoErrorKind;
use std::path::Path;
use std::process::Command;

use upac_types::traits::Booter;

use super::error::GrubError;
use super::grub::{
    INSTALL_BIN_FALLBACK, INSTALL_BIN_PRIMARY, INSTALL_BOOTLOADER_ID, INSTALL_TARGET, REBOOT_BIN_FALLBACK,
    REBOOT_BIN_PRIMARY, SET_DEFAULT_BIN_FALLBACK, SET_DEFAULT_BIN_PRIMARY,
};

const GRUB_CFG_CONTENTS: &str = "insmod blscfg\nblscfg\n";

pub struct Grub;

impl Booter for Grub {
    type Error = GrubError;

    fn new() -> Result<Self, GrubError> {
        Ok(Grub)
    }

    fn set_one_shot(&mut self, entry_name: &str) -> Result<(), GrubError> {
        self.run_first_available([REBOOT_BIN_PRIMARY, REBOOT_BIN_FALLBACK], &[entry_name])
    }

    fn confirm_boot(&mut self, entry_name: &str, esp_mount_point: &str) -> Result<(), GrubError> {
        let _ = esp_mount_point;

        self.run_first_available([SET_DEFAULT_BIN_PRIMARY, SET_DEFAULT_BIN_FALLBACK], &[entry_name])
    }

    fn install(
        &mut self, esp_mount_point: &str, esp_partition_number: u32, esp_starting_lba: u64, esp_ending_lba: u64,
        esp_unique_partition_guid: [u8; 16], to_slot: &str, from_slot: &str,
    ) -> Result<(), GrubError> {
        let _ = (
            esp_partition_number,
            esp_starting_lba,
            esp_ending_lba,
            esp_unique_partition_guid,
            to_slot,
            from_slot,
        );

        self.run_first_available(
            [INSTALL_BIN_PRIMARY, INSTALL_BIN_FALLBACK],
            &[
                &format!("--target={INSTALL_TARGET}"),
                &format!("--efi-directory={esp_mount_point}"),
                &format!("--boot-directory={esp_mount_point}"),
                &format!("--bootloader-id={INSTALL_BOOTLOADER_ID}"),
                "--removable",
                "--no-nvram",
            ],
        )?;

        let grub_cfg = Path::new(esp_mount_point).join("grub").join("grub.cfg");
        if let Some(parent) = grub_cfg.parent() {
            create_dir_all(parent)?;
        }
        write(&grub_cfg, GRUB_CFG_CONTENTS)?;

        Ok(())
    }
}

impl Grub {
    fn run_first_available(&self, candidates: [&str; 2], args: &[&str]) -> Result<(), GrubError> {
        for candidate in candidates {
            match Command::new(candidate).args(args).status() {
                Ok(status) if status.success() => return Ok(()),
                Ok(_) => return Err(GrubError::Unexpected),
                Err(error) if error.kind() == IoErrorKind::NotFound => continue,
                Err(error) => return Err(GrubError::from(error)),
            }
        }

        Err(GrubError::ToolNotFound)
    }
}
