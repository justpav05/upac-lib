// ── Imports ─────────────────────────────────────────────────────────────────
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
    // Constructs a CSlice from a Rust string slice
    pub fn from_str(string: &str) -> Self {
        Self {
            ptr: string.as_ptr(),
            len: string.len(),
        }
    }

    // Returns a &str view of the CSlice, assuming it contains valid UTF-8
    pub unsafe fn as_str(&self) -> &str {
        let slice = slice::from_raw_parts(self.ptr, self.len);
        str::from_utf8_unchecked(slice)
    }
}

// ── Metadata and Packages ──────────────────────────────────────────────────────
// Describes a specific package for installation, including the temporary path and checksum
#[repr(C)]
pub struct CPackageEntry {
    pub meta: CPackageMeta,
    pub temp_path: CSlice,
    pub checksum: CSlice,
}

// A structure containing the package description (name, version, author, etc.) in FFI format
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

// Represents a dynamic array of metadata allocated on the Zig side
#[repr(C)]
pub struct CPackageMetaArray {
    pub ptr: *mut CPackageMeta,
    pub len: usize,
}

// ── Requests ───────────────────────────────────────────────────────────────────
// Data container for the installation operation: list of packages, paths, and repository settings
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

// Data container for the uninstallation operation: list of package names and repository settings
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

// Data container for the rollback operation: paths and repository settings
#[repr(C)]
pub struct CRollbackRequest {
    pub root_path: CSlice,
    pub repo_path: CSlice,

    pub branch: CSlice,

    pub commit_hash: CSlice,
}

// ── Diff ──────────────────────────────────────────────────────────────────────
// Change type (added, deleted, modified) for files or packages
#[repr(u8)]
#[derive(Clone, Copy, Debug)]
pub enum CDiffKind {
    Added = 0,
    Removed = 1,
    Modified = 2,
}

// Data container for a single diff entry (file or package)
#[repr(C)]
pub struct CDiffEntry {
    pub path: CSlice,
    pub kind: CDiffKind,
}

// Data container for an array of diff entries
#[repr(C)]
pub struct CDiffArray {
    pub ptr: *mut CDiffEntry,
    pub len: usize,
}

// ── Package Diff ──────────────────────────────────────────────────────────────
// Change type (added, deleted, updated) for packages
#[repr(u8)]
#[derive(Clone, Copy, Debug)]
pub enum CPackageDiffKind {
    Added = 0,
    Removed = 1,
    Updated = 2,
}

// Data container for a single package diff entry
#[repr(C)]
pub struct CPackageDiffEntry {
    pub name: CSlice,
    pub kind: CPackageDiffKind,
}

// Data container for an array of package diff entries
#[repr(C)]
pub struct CPackageDiffArray {
    pub ptr: *mut CPackageDiffEntry,
    pub len: usize,
}

// Data container for a single attributed diff entry (file with package name)
#[repr(C)]
pub struct CAttributedDiffEntry {
    pub path: CSlice,
    pub kind: CDiffKind,
    pub package_name: CSlice,
}

// Data container for an array of attributed diff entries
#[repr(C)]
pub struct CAttributedDiffArray {
    pub ptr: *mut CAttributedDiffEntry,
    pub len: usize,
}

// ── Commits ───────────────────────────────────────────────────────────────────
// Data container for a single commit entry
#[repr(C)]
pub struct CCommitEntry {
    pub checksum: CSlice,
    pub subject: CSlice,
}

// Data container for an array of commit entries
#[repr(C)]
pub struct CCommitArray {
    pub ptr: *mut CCommitEntry,
    pub len: usize,
}

// ── Init ──────────────────────────────────────────────────────────────────────
// Data container for the system paths (repo and root)
#[repr(C)]
pub struct CSystemPaths {
    pub repo_path: CSlice,
    pub root_path: CSlice,
}

// Data container for the init request (system paths, repo mode, and branch)
#[repr(C)]
pub struct CInitRequest {
    pub system_paths: CSystemPaths,
    pub repo_mode: CRepoMode,
    pub branch: CSlice,
}

// Change type for the repository mode (archive, bare, bare-user)
#[repr(u8)]
#[derive(Clone, Copy)]
pub enum CRepoMode {
    Archive = 0,
    Bare = 1,
    BareUser = 2,
}
