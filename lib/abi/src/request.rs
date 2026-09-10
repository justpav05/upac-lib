// SPDX-FileCopyrightText: 2026 JustPav
// SPDX-FileCopyrightText: 2026 SmoothTeam
//
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

use std::os::raw::c_void;

use upac_macro::{CNew, CValidate};

use super::HookMessageFn;
use crate::error::ErrorKind;
use crate::hook::CancelToken;
use crate::package::CPackageInfo;
use crate::types::{CSlice, CVec, check_size};
use crate::{DiffFileSource, FileDiffKind};

#[repr(C)]
#[derive(CNew, CValidate)]
pub struct CRequestBase {
    pub struct_size: usize,

    pub on_hook: Option<HookMessageFn>,
    pub hook_ctx: *mut c_void,

    pub cancel_token: *mut CancelToken,
}

#[repr(C)]
#[derive(CNew, CValidate)]
pub struct CInstallRequest {
    pub struct_size: usize,
    pub base: CRequestBase,

    pub boot_plugin: CSlice,

    pub tmp_path: CSlice,

    pub subject: CSlice,
    #[optional]
    pub message: CSlice,

    pub packages: CVec<CSlice>,

    pub allow_conflict_files: bool,
}

#[repr(C)]
#[derive(CNew, CValidate)]
pub struct CUpdateRequest {
    pub struct_size: usize,
    pub base: CRequestBase,

    pub boot_plugin: CSlice,

    pub tmp_path: CSlice,

    pub subject: CSlice,
    #[optional]
    pub message: CSlice,

    pub packages: CVec<CSlice>,

    pub allow_downgrade: bool,
    pub allow_conflict_files: bool,
}

#[repr(C)]
#[derive(CNew, CValidate)]
pub struct CUninstallRequest {
    pub struct_size: usize,
    pub base: CRequestBase,

    pub boot_plugin: CSlice,

    pub tmp_path: CSlice,
    pub subject: CSlice,
    #[optional]
    pub message: CSlice,
    pub packages: CVec<CPackageInfo>,

    pub purge: bool,
}

#[repr(C)]
#[derive(CNew, CValidate)]
pub struct CRollbackRequest {
    pub struct_size: usize,
    pub base: CRequestBase,

    pub boot_plugin: CSlice,

    pub tmp_path: CSlice,
    pub config_digest: CSlice,
}

#[repr(C)]
#[derive(CNew, CValidate)]
pub struct CCommitRequest {
    pub struct_size: usize,
    pub base: CRequestBase,

    pub tmp_path: CSlice,
    pub subject: CSlice,
    #[optional]
    pub message: CSlice,
}

#[repr(C)]
#[derive(CNew, CValidate)]
pub struct CFilesRequest {
    pub struct_size: usize,
    pub base: CRequestBase,

    pub boot_plugin: CSlice,

    pub tmp_path: CSlice,
    pub subject: CSlice,
    #[optional]
    pub message: CSlice,
    pub files: CVec<CSlice>,
    pub file_kind: FileDiffKind,
    pub file_package: *const CPackageInfo,

    pub scope: DiffFileSource,
}

#[repr(C)]
#[derive(CNew, CValidate)]
pub struct CGcRequest {
    pub struct_size: usize,
    pub base: CRequestBase,
}

#[repr(C)]
#[derive(CNew, CValidate)]
pub struct CMimeSyncRequest {
    pub struct_size: usize,
    pub base: CRequestBase,
}

#[repr(C)]
#[derive(CNew, CValidate)]
pub struct CPinRequest {
    pub struct_size: usize,
    pub base: CRequestBase,

    #[non_empty]
    pub prefix_digest: CSlice,
    pub pinned: bool,
}

#[repr(C)]
#[derive(CNew, CValidate)]
pub struct CListPackagesRequest {
    pub struct_size: usize,
    pub base: CRequestBase,
}

#[repr(C)]
#[derive(CNew, CValidate)]
pub struct CListConfigRequest {
    pub struct_size: usize,
    pub base: CRequestBase,

    #[optional]
    pub prefix_digest: CSlice,
}

#[repr(C)]
#[derive(CNew, CValidate)]
pub struct CListPrefixRequest {
    pub struct_size: usize,
    pub base: CRequestBase,
}

#[repr(C)]
#[derive(CNew, CValidate)]
pub struct CListHistoryRequest {
    pub struct_size: usize,
    pub base: CRequestBase,
}

#[repr(C)]
#[derive(CNew, CValidate)]
pub struct CDiffPrefixRequest {
    pub struct_size: usize,
    pub base: CRequestBase,

    #[optional]
    pub from_prefix_digest: CSlice,
    #[optional]
    pub to_prefix_digest: CSlice,
}

#[repr(C)]
#[derive(CNew, CValidate)]
pub struct CDiffConfigRequest {
    pub struct_size: usize,
    pub base: CRequestBase,

    #[optional]
    pub from_config_digest: CSlice,
    #[optional]
    pub to_config_digest: CSlice,
}

#[repr(C)]
#[derive(CNew, CValidate)]
pub struct CDiffPackagesRequest {
    pub struct_size: usize,
    pub base: CRequestBase,

    #[optional]
    pub from_prefix_digest: CSlice,
    #[optional]
    pub to_prefix_digest: CSlice,
}

#[repr(C)]
#[derive(CNew, CValidate)]
pub struct CDiffRequest {
    pub struct_size: usize,
    pub base: CRequestBase,

    #[optional]
    pub from_prefix_digest: CSlice,
    #[optional]
    pub to_prefix_digest: CSlice,
    #[optional]
    pub from_config_digest: CSlice,
    #[optional]
    pub to_config_digest: CSlice,
}

#[repr(C)]
#[derive(CNew, CValidate)]
pub struct CSearchMetaRequest {
    pub struct_size: usize,
    pub base: CRequestBase,

    pub search: CSlice,
    pub is_regex: bool,
}

#[repr(C)]
#[derive(CNew, CValidate)]
pub struct CSearchFilesRequest {
    pub struct_size: usize,
    pub base: CRequestBase,

    pub search: CSlice,
    pub is_regex: bool,
}

#[repr(C)]
#[derive(CNew, CValidate)]
pub struct CSearchInMetaRequest {
    pub struct_size: usize,
    pub base: CRequestBase,

    pub package: CPackageInfo,
    pub search: CSlice,
    pub is_regex: bool,
}

#[repr(C)]
#[derive(CNew, CValidate)]
pub struct CSearchInPackageFilesRequest {
    pub struct_size: usize,
    pub base: CRequestBase,

    pub package: CPackageInfo,
    pub search: CSlice,
    pub is_regex: bool,
}

#[repr(C)]
#[derive(CNew, CValidate)]
pub struct CDecodeRequest {
    pub struct_size: usize,

    pub package_path: CSlice,
    pub output_dir: CSlice,

    pub checksum: [u8; 32],

    pub cancel_token: *mut CancelToken,
}

#[repr(C)]
#[derive(CNew, CValidate)]
pub struct CBootPluginSetOneShotRequest {
    pub struct_size: usize,

    pub entry_name: CSlice,
}

#[repr(C)]
#[derive(CNew, CValidate)]
pub struct CBootPluginConfirmSuccsesBootRequest {
    pub struct_size: usize,

    pub entry_name: CSlice,
    pub esp_mount_point: CSlice,
}

#[repr(C)]
#[derive(CNew, CValidate)]
pub struct CBootPluginInstallRequest {
    pub struct_size: usize,

    pub esp_mount_point: CSlice,
    pub esp_partition_number: u32,
    pub esp_starting_lba: u64,
    pub esp_ending_lba: u64,
    pub esp_unique_partition_guid: [u8; 16],
    pub to_slot: CSlice,
    pub from_slot: CSlice,
}
