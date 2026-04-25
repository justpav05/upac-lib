// ── Imports ─────────────────────────────────────────────────────────────────
use std::ffi::c_void;
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

#[repr(C)]
pub struct CSliceArray {
    pub ptr: *const CSlice,
    pub len: usize,
}

impl CSliceArray {
    pub fn empty() -> Self {
        Self {
            ptr: std::ptr::null(),
            len: 0,
        }
    }

    pub fn from_slice(slice: &[CSlice]) -> Self {
        Self {
            ptr: slice.as_ptr(),
            len: slice.len(),
        }
    }
}

// ── Metadata and Packages ──────────────────────────────────────────────────────
// Describes a specific package for installation, including the temporary path and checksum
#[repr(C)]
#[derive(Clone, Copy)]
pub struct CPackageEntry {
    pub meta: PackageMetaHandle,
    pub temp_path: CSlice,
    pub checksum: CSlice,
}

pub type PackageMetaHandle = *mut std::ffi::c_void;

// ── Requests ───────────────────────────────────────────────────────────────────
// Represents the request struct for the backend's prepare function
#[repr(C)]
pub struct CPrepareRequest {
    struct_size: usize,
    checksum: CSlice,

    package_path: CSlice,
    temp_dir_path: CSlice,

    on_progress: Option<unsafe extern "C" fn(u8, CSlice, *mut c_void)>,
    progress_ctx: *mut c_void,
}

impl CPrepareRequest {
    pub fn new(
        package_path: &str,
        temp_dir_path: &str,
        checksum: &str,
        on_progress: Option<unsafe extern "C" fn(u8, CSlice, *mut c_void)>,
        progress_ctx: *mut c_void,
    ) -> Self {
        Self {
            struct_size: size_of::<CPrepareRequest>(),
            checksum: CSlice::from_str(checksum),

            package_path: CSlice::from_str(package_path),
            temp_dir_path: CSlice::from_str(temp_dir_path),

            on_progress,
            progress_ctx,
        }
    }
}

// Data container for the installation operation: list of packages, paths, and repository settings
#[repr(C)]
pub struct CInstallRequest {
    pub struct_size: usize,

    pub packages: *const CPackageEntry,
    pub packages_count: usize,

    pub repo_path: CSlice,
    pub root_path: CSlice,
    pub db_path: CSlice,

    pub branch: CSlice,
    pub prefix_directory: CSlice,

    pub on_progress: Option<CInstallProgressFn>,
    pub progress_ctx: *mut std::ffi::c_void,

    pub max_retries: u8,
}

pub type CInstallProgressFn =
    unsafe extern "C" fn(event: u8, package_name: CSlice, ctx: *mut c_void);

// Data container for the uninstallation operation: list of package names and repository settings
#[repr(C)]
pub struct CUninstallRequest {
    pub struct_size: usize,

    pub package_names: *const CSlice,
    pub package_names_len: usize,

    pub repo_path: CSlice,
    pub root_path: CSlice,
    pub db_path: CSlice,

    pub branch: CSlice,
    pub prefix_directory: CSlice,

    pub on_progress: Option<CUninstallProgressFn>,
    pub progress_ctx: *mut c_void,

    pub max_retries: u8,
}

pub type CUninstallProgressFn =
    unsafe extern "C" fn(event: u8, package_name: CSlice, ctx: *mut c_void);

// Data container for the rollback operation: paths and repository settings
#[repr(C)]
pub struct CRollbackRequest {
    pub struct_size: usize,

    pub root_path: CSlice,
    pub repo_path: CSlice,

    pub branch: CSlice,
    pub prefix_directory: CSlice,

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
// Data container for the init request (system paths, repo mode, and branch)
#[repr(C)]
pub struct CInitRequest {
    pub struct_size: usize,

    pub repo_path: CSlice,
    pub root_path: CSlice,

    pub prefix_directory: CSlice,
    pub addition_prefixes: CSliceArray,

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
