// ── Imports ─────────────────────────────────────────────────────────────────
use anyhow::{bail, Result};

use libloading::{Library, Symbol};

use std::slice;
use std::str;

// ── Types from Zig ABI ────────────────────────────────────────────────
// A String analogue for passing strings across the FFI boundary
#[repr(C)]
#[derive(Clone, Copy)]
pub struct CSlice {
    pub ptr: *const u8,
    pub len: usize,
}

impl CSlice {
    pub fn from_str(string: &str) -> Self {
        Self {
            ptr: string.as_ptr(),
            len: string.len(),
        }
    }

    pub unsafe fn as_str(&self) -> &str {
        let slice = slice::from_raw_parts(self.ptr, self.len);
        str::from_utf8_unchecked(slice)
    }
}

#[repr(C)]
pub struct CPackageEntry {
    pub meta: CPackageMeta,
    pub temp_path: CSlice,
    pub checksum: CSlice,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct CPackageMeta {
    pub name: CSlice,
    pub version: CSlice,
    pub author: CSlice,
    pub description: CSlice,
    pub license: CSlice,
    pub url: CSlice,
    pub installed_at: i64,
    pub checksum: CSlice,
}

#[repr(C)]
pub struct CPackageMetaArray {
    pub ptr: *mut CPackageMeta,
    pub len: usize,
}

// ── Запросы ───────────────────────────────────────────────────────────────────
#[repr(C)]
pub struct CInstallRequest {
    pub packages: *const CPackageEntry,
    pub packages_len: usize,

    pub repo_path: CSlice,
    pub root_path: CSlice,
    pub db_path: CSlice,

    pub branch: CSlice,

    pub max_retries: u8,
}

#[repr(C)]
pub struct CUninstallRequest {
    pub package_names: *const CSlice,
    pub package_names_len: usize,

    pub repo_path: CSlice,
    pub root_path: CSlice,
    pub db_path: CSlice,

    pub branch: CSlice,

    pub max_retries: u8,
}

#[repr(C)]
pub struct CRollbackRequest {
    pub root_path: CSlice,
    pub repo_path: CSlice,

    pub branch: CSlice,

    pub commit_hash: CSlice,
}

// ── Diff ──────────────────────────────────────────────────────────────────────
#[repr(u8)]
#[derive(Clone, Copy, Debug)]
pub enum CDiffKind {
    Added = 0,
    Removed = 1,
    Modified = 2,
}

#[repr(C)]
pub struct CDiffEntry {
    pub path: CSlice,
    pub kind: CDiffKind,
}

#[repr(C)]
pub struct CDiffArray {
    pub ptr: *mut CDiffEntry,
    pub len: usize,
}

// ── Package Diff ──────────────────────────────────────────────────────────────

#[repr(u8)]
#[derive(Clone, Copy, Debug)]
pub enum CPackageDiffKind {
    Added = 0,
    Removed = 1,
    Updated = 2,
}

#[repr(C)]
pub struct CPackageDiffEntry {
    pub name: CSlice,
    pub kind: CPackageDiffKind,
}

#[repr(C)]
pub struct CPackageDiffArray {
    pub ptr: *mut CPackageDiffEntry,
    pub len: usize,
}

#[repr(C)]
pub struct CAttributedDiffEntry {
    pub path: CSlice,
    pub kind: CDiffKind,
    pub package_name: CSlice,
}

#[repr(C)]
pub struct CAttributedDiffArray {
    pub ptr: *mut CAttributedDiffEntry,
    pub len: usize,
}

// ── Commits ───────────────────────────────────────────────────────────────────
#[repr(C)]
pub struct CCommitEntry {
    pub checksum: CSlice,
    pub subject: CSlice,
}

#[repr(C)]
pub struct CCommitArray {
    pub ptr: *mut CCommitEntry,
    pub len: usize,
}

// ── Init ──────────────────────────────────────────────────────────────────────
#[repr(C)]
pub struct CSystemPaths {
    pub repo_path: CSlice,
    pub root_path: CSlice,
}

#[repr(C)]
pub struct CInitRequest {
    pub system_paths: CSystemPaths,
    pub repo_mode: CRepoMode,
    pub branch: CSlice,
}

#[repr(u8)]
#[derive(Clone, Copy)]
pub enum CRepoMode {
    Archive = 0,
    Bare = 1,
    BareUser = 2,
}
