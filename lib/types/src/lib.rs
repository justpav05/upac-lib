// SPDX-FileCopyrightText: 2026 JustPav
// SPDX-FileCopyrightText: 2026 SmoothTeam
//
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

use upac_abi::FsKind;

use self::package::{PackageEntry, PackageMeta};

pub mod codec;
pub mod decoder;
pub mod entry;
pub mod error;
pub mod hook;
pub mod package;
pub mod request;
pub mod response;
pub mod settings;
pub mod states;
pub mod traits;

macro_rules! as_str_method {
    ($name:ty) => {
        impl AsRef<str> for $name {
            fn as_ref(&self) -> &str {
                &self.0
            }
        }
    };
}

pub struct UninstallPackagesTargets(pub Vec<PackageEntry>);

impl UninstallPackagesTargets {
    pub fn entries(&self) -> &[PackageEntry] {
        &self.0
    }
}

pub struct TmpPath(pub String);

as_str_method!(TmpPath);

pub struct RequestedPrefixDigest(pub Option<String>);

pub struct RequestedPrefixDigestRange {
    pub from: Option<String>,
    pub to: Option<String>,
}

pub struct RequestedConfigDigestRange {
    pub from: Option<String>,
    pub to: Option<String>,
}

pub struct DiffPackagesSnapshot {
    pub from: Vec<PackageMeta>,
    pub to: Vec<PackageMeta>,
}

// ── PartitionMount / PartitionSpec (bootstrap setup) ────────────────────────
#[derive(Debug, Clone)]
pub struct PartitionMount {
    pub mount_path: String,
    pub device_path: String,
    pub fs_kind: FsKind,
}

#[derive(Debug, Clone)]
pub struct PartitionSpec {
    pub mount_path: String,
    pub size_mib: u64,
    pub fs_kind: FsKind,
}

#[derive(Debug, Clone)]
pub struct GptLayout {
    pub esp_size_mib: u64,
    pub deploy_fs: FsKind,
    pub deploy_size_mib: u64,
    pub extra_partitions: Vec<PartitionSpec>,
    pub force_wipe: bool,
}

#[derive(Debug, Clone)]
pub struct BtrfsOptions {
    pub node_size: u32,
    pub sector_size: u32,
}
