// SPDX-FileCopyrightText: 2026 JustPav
// SPDX-FileCopyrightText: 2026 SmoothTeam
//
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

use std::mem::size_of;

use upac_abi::package::CVersion;
use upac_abi::response::{
    CConfigCommitEntry, CDiffConfigFileEntry, CDiffFileEntryCommon, CDiffPackageEntry, CDiffPrefixFileEntry,
    CDiffUntrackedFileEntry, CHistoryEntry, CPrefixEntry, CSearchFileEntry,
};
use upac_abi::types::{COwned, CSlice, CVec};
use upac_abi::{DiffFileSource, FileDiffKind, PackageDiffKind};

use upac_macro::{RedbCodec, RustToC};

use crate::codec::RedbCodable;
use crate::package::Version;

// ── FileEntryScope ──────────────────────────────────────────────────────────
#[repr(u8)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FileEntryScope {
    Prefix = 0,
    Config = 1,
}

impl RedbCodable for FileEntryScope {
    fn redb_encode(&self, buf: &mut Vec<u8>) {
        buf.push(*self as u8);
    }

    fn redb_decode(data: &[u8], offset: &mut usize) -> FileEntryScope {
        let value = data[*offset];
        *offset += 1;

        match value {
            1 => FileEntryScope::Config,
            _ => FileEntryScope::Prefix,
        }
    }
}

// ── FileEntry ───────────────────────────────────────────────────────────────
#[derive(Debug, Clone, RedbCodec)]
pub struct FileEntry {
    pub path: String,
    pub is_user: bool,
    pub scope: FileEntryScope,
}

// ── SearchFileEntry ─────────────────────────────────────────────────────────
#[derive(Debug, Clone, RustToC)]
pub struct SearchFileEntry {
    pub path: String,
    pub package_name: String,
    pub is_user: bool,
}

// ── PrefixEntry ─────────────────────────────────────────────────────────────
#[derive(Debug, Clone, RustToC)]
pub struct PrefixEntry {
    pub prefix_digest: String,

    pub subject: String,
    pub message: Option<String>,

    pub timestamp: u64,

    pub working_config: Option<String>,
}

// ── ConfigCommitEntry ─────────────────────────────────────────────────────────────
#[derive(Debug, Clone, RustToC)]
pub struct ConfigCommitEntry {
    pub config_digest: String,

    pub subject: String,
    pub message: Option<String>,
}

// ── HistoryEntry ────────────────────────────────────────────────────────────
#[derive(Debug, Clone, RustToC)]
pub struct HistoryEntry {
    pub prefix_digest: String,

    pub subject: String,
    pub message: Option<String>,

    pub timestamp: u64,

    pub working_config: Option<String>,
    pub config_history: Vec<ConfigCommitEntry>,
}

// ── DiffFileEntryCommon ──────────────────────────────────────────────────────
#[derive(Debug, Clone, RustToC)]
pub struct DiffFileEntryCommon {
    pub path: String,
    pub kind: FileDiffKind,
}

// ── DiffPrefixFileEntry ─────────────────────────────────────────────────────
#[derive(Debug, Clone, RustToC)]
pub struct DiffPrefixFileEntry {
    pub common: DiffFileEntryCommon,
    pub source: DiffFileSource,
    pub package_name: String,
    pub is_user: bool,
}

// ── DiffConfigFileEntry ─────────────────────────────────────────────────────
#[derive(Debug, Clone, RustToC)]
pub struct DiffConfigFileEntry {
    pub common: DiffFileEntryCommon,
    pub package_name: Option<String>,
}

// ── DiffPackageEntry ────────────────────────────────────────────────────────
#[derive(Debug, Clone, RustToC)]
pub struct DiffPackageEntry {
    pub name: String,
    pub kind: PackageDiffKind,
    pub version: Version,

    pub files: Vec<DiffPrefixFileEntry>,
}

// ── DiffUntrackedFileEntry ──────────────────────────────────────────────────
#[derive(Debug, Clone, RustToC)]
pub struct DiffUntrackedFileEntry {
    pub common: DiffFileEntryCommon,
    pub source: DiffFileSource,
}
