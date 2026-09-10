// SPDX-FileCopyrightText: 2026 JustPav
// SPDX-FileCopyrightText: 2026 SmoothTeam
//
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

use std::fs::{File, OpenOptions};
use std::path::{Path, PathBuf};
use std::thread::sleep;
use std::time::Duration;

use gptman::linux::{get_sector_size, reread_partition_table};
use gptman::{GPT, GPTPartitionEntry};

use uuid::{Uuid, uuid};

use upac_types::PartitionSpec;

use crate::error::SetupError;
use crate::format::FormatTarget;
use crate::layout::partition::{DEPLOY_LABEL, ESP_LABEL, SETTLE_ATTEMPTS, SETTLE_INTERVAL_MS};

#[cfg(test)]
#[path = "../tests/inline/partition.rs"]
mod tests;

macro_rules! mib_to_sectors {
    ($size_mib:expr, $sector_size:expr) => {
        $size_mib * 1024 * 1024 / $sector_size
    };
}

const ESP_PARTITION_TYPE_GUID: Uuid = uuid!("c12a7328-f81f-11d2-ba4b-00a0c93ec93b");
const LINUX_PARTITION_TYPE_GUID: Uuid = uuid!("0fc63daf-8483-4772-8e79-3d69d8477de4");
const LINUX_ROOT_X86_64_GUID: Uuid = uuid!("4f68bce3-e8cd-4db1-96e7-fbcaf984b709");

#[repr(transparent)]
struct GptTable(GPT);

impl GptTable {
    fn new(device: &mut File, sector_size: u64) -> Result<Self, SetupError> {
        Ok(GptTable(GPT::new_from(
            device,
            sector_size,
            Uuid::new_v4().to_bytes_le(),
        )?))
    }

    fn insert_partition(
        &mut self, number: u32, partition_type: Uuid, name: &str, size_sectors: u64,
    ) -> Result<GPTPartitionEntry, SetupError> {
        let starting_lba = self.0.find_first_place(size_sectors).ok_or(SetupError::NoSpaceLeft)?;
        let ending_lba = starting_lba + size_sectors - 1;

        let entry = GPTPartitionEntry {
            partition_type_guid: partition_type.to_bytes_le(),
            unique_partition_guid: Uuid::new_v4().to_bytes_le(),
            starting_lba,
            ending_lba,
            attribute_bits: 0,
            partition_name: name.into(),
        };

        self.0[number] = entry.clone();

        Ok(entry)
    }

    fn write_into(&mut self, device: &mut File) -> Result<(), SetupError> {
        self.0.write_into(device)?;

        Ok(())
    }
}

pub struct DiskLayout {
    device_path: PathBuf,
    esp_partition: u32,
    esp_starting_lba: u64,
    esp_ending_lba: u64,
    esp_unique_partition_guid: Uuid,
    deploy_partition: u32,
    extra_partitions: Vec<u32>,
}

impl DiskLayout {
    pub fn create(
        device_path: &Path, esp_size_mib: u64, deploy_size_mib: u64, extra_partitions: &[PartitionSpec],
        force_wipe: bool,
    ) -> Result<Self, SetupError> {
        if force_wipe {
            FormatTarget {
                device_path,
                label: None,
            }
            .wipe_signature()?;
        }

        let mut device = OpenOptions::new().read(true).write(true).open(device_path)?;

        let sector_size = get_sector_size(&mut device).unwrap_or(512);
        let mut gpt = GptTable::new(&mut device, sector_size)?;

        let mut next_number = 1;

        let esp_partition = next_number;
        let esp_entry = gpt.insert_partition(
            esp_partition,
            ESP_PARTITION_TYPE_GUID,
            ESP_LABEL,
            mib_to_sectors!(esp_size_mib, sector_size),
        )?;
        next_number += 1;

        let deploy_partition = next_number;
        gpt.insert_partition(
            deploy_partition,
            LINUX_ROOT_X86_64_GUID,
            DEPLOY_LABEL,
            mib_to_sectors!(deploy_size_mib, sector_size),
        )?;
        next_number += 1;

        let mut extras = Vec::with_capacity(extra_partitions.len());
        for extra in extra_partitions {
            gpt.insert_partition(
                next_number,
                LINUX_PARTITION_TYPE_GUID,
                &extra.mount_path,
                mib_to_sectors!(extra.size_mib, sector_size),
            )?;
            extras.push(next_number);
            next_number += 1;
        }

        GPT::write_protective_mbr_into(&mut device, sector_size)?;
        gpt.write_into(&mut device)?;
        reread_partition_table(&mut device)?;

        let layout = DiskLayout {
            device_path: device_path.to_owned(),
            esp_partition,
            esp_starting_lba: esp_entry.starting_lba,
            esp_ending_lba: esp_entry.ending_lba,
            esp_unique_partition_guid: Uuid::from_bytes_le(esp_entry.unique_partition_guid),
            deploy_partition,
            extra_partitions: extras,
        };
        layout.wait_until_ready()?;

        Ok(layout)
    }

    fn wait_until_ready(&self) -> Result<(), SetupError> {
        let mut paths = vec![self.esp_path(), self.deploy_path()];
        paths.extend(self.extra_paths());

        for path in &paths {
            let mut ready = false;

            for _ in 0..SETTLE_ATTEMPTS {
                if path.exists() {
                    ready = true;
                    break;
                }
                sleep(Duration::from_millis(u64::from(SETTLE_INTERVAL_MS)));
            }

            if !ready {
                return Err(SetupError::PartitionNotReady);
            }
        }

        Ok(())
    }

    pub fn esp_path(&self) -> PathBuf {
        self.partition_path(self.esp_partition)
    }

    pub fn esp_partition_number(&self) -> u32 {
        self.esp_partition
    }

    pub fn esp_starting_lba(&self) -> u64 {
        self.esp_starting_lba
    }

    pub fn esp_ending_lba(&self) -> u64 {
        self.esp_ending_lba
    }

    pub fn esp_unique_partition_guid(&self) -> Uuid {
        self.esp_unique_partition_guid
    }

    pub fn deploy_path(&self) -> PathBuf {
        self.partition_path(self.deploy_partition)
    }

    pub fn extra_paths(&self) -> Vec<PathBuf> {
        self.extra_partitions
            .iter()
            .map(|&number| self.partition_path(number))
            .collect()
    }

    fn partition_path(&self, number: u32) -> PathBuf {
        let ends_in_digit = self
            .device_path
            .file_name()
            .and_then(|name| name.to_str())
            .and_then(|name| name.chars().next_back())
            .is_some_and(|last| last.is_ascii_digit());

        let separator = if ends_in_digit { "p" } else { "" };

        PathBuf::from(format!("{}{separator}{number}", self.device_path.display()))
    }
}
