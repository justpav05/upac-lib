// SPDX-FileCopyrightText: 2026 JustPav
// SPDX-FileCopyrightText: 2026 SmoothTeam
//
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

use std::path::PathBuf;

use uuid::Uuid;

use super::DiskLayout;

fn layout(device_path: &str, extra_partitions: Vec<u32>) -> DiskLayout {
    DiskLayout {
        device_path: PathBuf::from(device_path),
        esp_partition: 1,
        esp_starting_lba: 2048,
        esp_ending_lba: 2048 + 1024 * 1024 / 512 - 1,
        esp_unique_partition_guid: Uuid::new_v4(),
        deploy_partition: 2,
        extra_partitions,
    }
}

#[test]
fn esp_and_deploy_path_append_partition_number_for_a_plain_device_name() {
    let layout = layout("/dev/sda", Vec::new());

    assert_eq!(layout.esp_path(), PathBuf::from("/dev/sda1"));
    assert_eq!(layout.deploy_path(), PathBuf::from("/dev/sda2"));
}

#[test]
fn partition_paths_insert_a_p_separator_when_the_device_name_ends_in_a_digit() {
    let layout = layout("/dev/nvme0n1", Vec::new());

    assert_eq!(layout.esp_path(), PathBuf::from("/dev/nvme0n1p1"));
    assert_eq!(layout.deploy_path(), PathBuf::from("/dev/nvme0n1p2"));
}

#[test]
fn extra_paths_maps_each_extra_partition_number_in_order() {
    let layout = layout("/dev/sda", vec![3, 4]);

    assert_eq!(
        layout.extra_paths(),
        vec![PathBuf::from("/dev/sda3"), PathBuf::from("/dev/sda4")]
    );
}
