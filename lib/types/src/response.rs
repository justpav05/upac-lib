// SPDX-FileCopyrightText: 2026 JustPav
// SPDX-FileCopyrightText: 2026 SmoothTeam
//
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

use std::mem::size_of;

use upac_abi::error::ErrorKind;
use upac_abi::package::CPackageMeta;
use upac_abi::response::{
    CConfigCommitEntry, CDecodeResponse, CDiffConfigFileEntry, CDiffConfigResponse, CDiffPackageEntry,
    CDiffPackagesResponse, CDiffPrefixFileEntry, CDiffPrefixResponse, CDiffResponse, CDiffUntrackedFileEntry,
    CHistoryEntry, CListConfigResponse, CListHistoryResponse, CListPackagesResponse, CListPrefixResponse, CPrefixEntry,
    CSearchFileEntry, CSearchFilesResponse, CSearchInMetaResponse, CSearchInPackageFilesResponse, CSearchMetaResponse,
};
use upac_abi::types::{COwned, CVec};

use upac_macro::{CTryToRust, RustToC};

use super::entry::{
    ConfigCommitEntry, DiffConfigFileEntry, DiffPackageEntry, DiffPrefixFileEntry, DiffUntrackedFileEntry,
    HistoryEntry, PrefixEntry, SearchFileEntry,
};
use super::package::{PackageDependency, PackageMeta};

#[derive(Debug, Clone, RustToC)]
pub struct ListConfigResponse {
    pub commits: Vec<ConfigCommitEntry>,
}

#[derive(Debug, Clone, RustToC)]
pub struct ListPackagesResponse {
    pub metas: Vec<PackageMeta>,
}

#[derive(Debug, Clone, RustToC)]
pub struct SearchMetaResponse {
    pub metas: Vec<PackageMeta>,
}

#[derive(Debug, Clone, RustToC)]
pub struct SearchFilesResponse {
    pub files: Vec<SearchFileEntry>,
}

#[derive(Debug, Clone, RustToC)]
pub struct SearchInMetaResponse {
    pub metas: Vec<PackageMeta>,
}

#[derive(Debug, Clone, RustToC)]
pub struct SearchInPackageFilesResponse {
    pub files: Vec<SearchFileEntry>,
}

#[derive(Debug, Clone, RustToC)]
pub struct ListPrefixResponse {
    pub prefixes: Vec<PrefixEntry>,
}

#[derive(Debug, Clone, RustToC)]
pub struct ListHistoryResponse {
    pub history: Vec<HistoryEntry>,
}

#[derive(Debug, Clone, RustToC)]
pub struct DiffPrefixResponse {
    pub files: Vec<DiffPrefixFileEntry>,
}

#[derive(Debug, Clone, RustToC)]
pub struct DiffConfigResponse {
    pub files: Vec<DiffConfigFileEntry>,
}

#[derive(Debug, Clone, RustToC)]
pub struct DiffPackagesResponse {
    pub diff_packages: Vec<DiffPackageEntry>,
}

#[derive(Debug, Clone, RustToC)]
pub struct DiffResponse {
    pub diff_packages: Vec<DiffPackageEntry>,
    pub unattached_files: Vec<DiffUntrackedFileEntry>,
}

#[derive(Debug, Clone, CTryToRust)]
pub struct DecodeResponse {
    pub meta: PackageMeta,
    pub dependencies: Vec<PackageDependency>,
    pub declarative_triggers: Vec<String>,
}
