// SPDX-FileCopyrightText: 2026 JustPav
// SPDX-FileCopyrightText: 2026 SmoothTeam
//
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

use upac_macro::{CFree, CNew, CValidate};

use crate::FreeDecodeResponseFn;
use crate::error::ErrorKind;
use crate::memory::{free_cslice, free_cvec_owning};
use crate::package::{CPackageDependency, CPackageMeta, CVersion};
use crate::types::{CSlice, CVec, check_size};
use crate::{DiffFileSource, FileDiffKind, PackageDiffKind};

#[repr(C)]
#[derive(CFree, CNew, CValidate)]
pub struct CDiffPackageEntry {
    pub struct_size: usize,

    pub name: CSlice,
    pub kind: PackageDiffKind,
    pub version: CVersion,
    pub files: CVec<CDiffPrefixFileEntry>,
}

#[repr(C)]
#[derive(CFree, CNew, CValidate)]
pub struct CDiffFileEntryCommon {
    pub struct_size: usize,

    pub path: CSlice,
    pub kind: FileDiffKind,
}

#[repr(C)]
#[derive(CFree, CNew, CValidate)]
pub struct CDiffPrefixFileEntry {
    pub struct_size: usize,

    pub common: CDiffFileEntryCommon,
    pub source: DiffFileSource,
    pub package_name: CSlice,
    pub is_user: bool,
}

#[repr(C)]
#[derive(CFree, CNew, CValidate)]
pub struct CDiffConfigFileEntry {
    pub struct_size: usize,

    pub common: CDiffFileEntryCommon,
    #[optional]
    pub package_name: CSlice,
}

#[repr(C)]
#[derive(CFree, CNew, CValidate)]
pub struct CDiffUntrackedFileEntry {
    pub struct_size: usize,

    pub common: CDiffFileEntryCommon,
    pub source: DiffFileSource,
}

#[repr(C)]
#[derive(CFree, CNew, CValidate)]
pub struct CConfigCommitEntry {
    pub struct_size: usize,

    pub config_digest: CSlice,
    pub subject: CSlice,
    #[optional]
    pub message: CSlice,
}

#[repr(C)]
#[derive(CFree, CNew, CValidate)]
pub struct CListConfigResponse {
    pub struct_size: usize,
    pub commits: CVec<CConfigCommitEntry>,
}

#[repr(C)]
#[derive(CFree, CNew, CValidate)]
pub struct CListPackagesResponse {
    pub struct_size: usize,
    pub metas: CVec<CPackageMeta>,
}

#[repr(C)]
#[derive(CFree, CNew, CValidate)]
pub struct CSearchMetaResponse {
    pub struct_size: usize,
    pub metas: CVec<CPackageMeta>,
}

#[repr(C)]
#[derive(CFree, CNew, CValidate)]
pub struct CSearchFileEntry {
    pub struct_size: usize,

    pub path: CSlice,
    pub package_name: CSlice,
    pub is_user: bool,
}

#[repr(C)]
#[derive(CFree, CNew, CValidate)]
pub struct CSearchFilesResponse {
    pub struct_size: usize,
    pub files: CVec<CSearchFileEntry>,
}

#[repr(C)]
#[derive(CFree, CNew, CValidate)]
pub struct CSearchInMetaResponse {
    pub struct_size: usize,
    pub metas: CVec<CPackageMeta>,
}

#[repr(C)]
#[derive(CFree, CNew, CValidate)]
pub struct CSearchInPackageFilesResponse {
    pub struct_size: usize,
    pub files: CVec<CSearchFileEntry>,
}

#[repr(C)]
#[derive(CFree, CNew, CValidate)]
pub struct CPrefixEntry {
    pub struct_size: usize,

    pub prefix_digest: CSlice,
    pub subject: CSlice,
    #[optional]
    pub message: CSlice,
    pub timestamp: u64,
    #[optional]
    pub working_config: CSlice,
}

#[repr(C)]
#[derive(CFree, CNew, CValidate)]
pub struct CListPrefixResponse {
    pub struct_size: usize,
    pub prefixes: CVec<CPrefixEntry>,
}

#[repr(C)]
#[derive(CFree, CNew, CValidate)]
pub struct CHistoryEntry {
    pub struct_size: usize,

    pub prefix_digest: CSlice,
    pub subject: CSlice,
    #[optional]
    pub message: CSlice,
    pub timestamp: u64,
    #[optional]
    pub working_config: CSlice,
    pub config_history: CVec<CConfigCommitEntry>,
}

#[repr(C)]
#[derive(CFree, CNew, CValidate)]
pub struct CListHistoryResponse {
    pub struct_size: usize,
    pub history: CVec<CHistoryEntry>,
}

#[repr(C)]
#[derive(CFree, CNew, CValidate)]
pub struct CDiffPrefixResponse {
    pub struct_size: usize,
    pub files: CVec<CDiffPrefixFileEntry>,
}

#[repr(C)]
#[derive(CFree, CNew, CValidate)]
pub struct CDiffConfigResponse {
    pub struct_size: usize,
    pub files: CVec<CDiffConfigFileEntry>,
}

#[repr(C)]
#[derive(CFree, CNew, CValidate)]
pub struct CDiffPackagesResponse {
    pub struct_size: usize,
    pub diff_packages: CVec<CDiffPackageEntry>,
}

#[repr(C)]
#[derive(CFree, CNew, CValidate)]
pub struct CDiffResponse {
    pub struct_size: usize,
    pub diff_packages: CVec<CDiffPackageEntry>,
    pub unattached_files: CVec<CDiffUntrackedFileEntry>,
}

#[repr(C)]
#[derive(CValidate, CNew)]
pub struct CDecodeResponse {
    pub struct_size: usize,

    pub meta: CPackageMeta,

    pub dependencies: CVec<CPackageDependency>,
    pub declarative_triggers: CVec<CSlice>,

    pub free: FreeDecodeResponseFn,
}

impl Drop for CDecodeResponse {
    fn drop(&mut self) {
        unsafe { (self.free)(self) };
    }
}
