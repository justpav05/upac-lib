// SPDX-FileCopyrightText: 2026 JustPav
// SPDX-FileCopyrightText: 2026 SmoothTeam
//
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

use std::ptr::null_mut;

use upac_abi::FsKind;
use upac_abi::hook::CancelToken;

use upac_setup::data::{SetupExistingData, SetupWholeDiskData};

fn existing_data<'data>(cancel_token: &'data CancelToken, mount_point: Option<&'data str>) -> SetupExistingData<'data> {
    SetupExistingData {
        esp_device: "/dev/sda1",
        deploy_device: "/dev/sda2",
        deploy_fs: FsKind::Ext4,
        extra_mounts: Vec::new(),

        mount_point,
        source: "/mnt/source",
        empty_config: false,
        pinned: false,
        boot_plugin: None,

        hook_message: None,
        hook_message_context: null_mut(),

        cancel_token,
    }
}

fn whole_disk_data<'data>(
    cancel_token: &'data CancelToken, mount_point: Option<&'data str>,
) -> SetupWholeDiskData<'data> {
    SetupWholeDiskData {
        device_path: "/dev/sda",
        esp_size_mib: 512,
        deploy_fs: FsKind::Ext4,
        deploy_size_mib: 8192,
        extra_partitions: Vec::new(),
        force_wipe: false,

        node_size: 0,
        sector_size: 0,

        mount_point,
        source: "/mnt/source",
        empty_config: false,
        pinned: false,
        boot_plugin: None,

        hook_message: None,
        hook_message_context: null_mut(),

        cancel_token,
    }
}

#[test]
fn setup_existing_data_mount_point_returns_explicit_value_when_given() {
    let cancel_token = CancelToken::new();
    let data = existing_data(&cancel_token, Some("/custom/mount"));

    assert_eq!(data.mount_point(), "/custom/mount");
}

#[test]
fn setup_existing_data_mount_point_falls_back_to_the_configured_default() {
    let cancel_token = CancelToken::new();
    let data = existing_data(&cancel_token, None);

    assert_eq!(data.mount_point(), "/mnt/upac-setup");
}

#[test]
fn setup_whole_disk_data_mount_point_returns_explicit_value_when_given() {
    let cancel_token = CancelToken::new();
    let data = whole_disk_data(&cancel_token, Some("/custom/mount"));

    assert_eq!(data.mount_point(), "/custom/mount");
}

#[test]
fn setup_whole_disk_data_mount_point_falls_back_to_the_configured_default() {
    let cancel_token = CancelToken::new();
    let data = whole_disk_data(&cancel_token, None);

    assert_eq!(data.mount_point(), "/mnt/upac-setup");
}
