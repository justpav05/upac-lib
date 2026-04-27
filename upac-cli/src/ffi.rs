// ── Imports ─────────────────────────────────────────────────────────────────
use anyhow::Result;

use std::ffi::c_void;
use std::ptr::null;
use std::slice;
use std::str;

pub trait Validate {
    fn validate(&self) -> Result<()>;
}

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

impl Validate for CSlice {
    fn validate(&self) -> Result<()> {
        if self.ptr.is_null() || self.len == 0 {
            return Err(anyhow::anyhow!("empty slice"));
        }
        if unsafe { *self.ptr.add(self.len) } != 0 {
            return Err(anyhow::anyhow!("not null-terminated"));
        }
        Ok(())
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
            ptr: null(),
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
pub type PackageMetaHandle = *mut c_void;
// Describes a specific package for installation, including the temporary path and checksum
#[repr(C)]
#[derive(Clone, Copy)]
pub struct CPackageEntry {
    struct_size: usize,

    meta: PackageMetaHandle,
    temp_path: CSlice,
    checksum: CSlice,
}

impl CPackageEntry {
    pub fn new(meta: PackageMetaHandle, temp_path: &str, checksum: &str) -> Self {
        Self {
            struct_size: size_of::<CPackageEntry>(),

            meta,
            temp_path: CSlice::from_str(temp_path),
            checksum: CSlice::from_str(checksum),
        }
    }
}

impl Validate for CPackageEntry {
    fn validate(&self) -> Result<()> {
        if self.struct_size != size_of::<CPackageEntry>() {
            return Err(anyhow::anyhow!("CPackageEntry: abi mismatch"));
        }
        if self.meta.is_null() {
            return Err(anyhow::anyhow!("CPackageEntry: meta is null"));
        }
        self.temp_path.validate()?;
        self.checksum.validate()?;
        Ok(())
    }
}

// ── Requests ───────────────────────────────────────────────────────────────────
// Represents the request struct for the backend's prepare function
#[repr(C)]
pub struct CPrepareRequest {
    struct_size: usize,
    checksum: CSlice,

    package_path: CSlice,
    temp_dir_path: CSlice,

    on_progress: unsafe extern "C" fn(u8, CSlice, *mut c_void),
    progress_ctx: *mut c_void,
}

impl CPrepareRequest {
    pub fn new(
        package_path: &str,
        temp_dir_path: &str,
        checksum: &str,
        on_progress: unsafe extern "C" fn(u8, CSlice, *mut c_void),
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
    struct_size: usize,

    packages: *const CPackageEntry,
    packages_count: usize,

    repo_path: CSlice,
    root_path: CSlice,
    db_path: CSlice,

    branch: CSlice,
    prefix_directory: CSlice,

    on_progress: Option<CInstallProgressFn>,
    progress_ctx: *mut std::ffi::c_void,

    max_retries: u8,
}

impl CInstallRequest {
    pub fn new(
        packages: &[CPackageEntry],
        repo_path: &str,
        root_path: &str,
        db_path: &str,
        branch: &str,
        prefix_directory: &str,
        max_retries: u8,
        on_progress: Option<CInstallProgressFn>,
        progress_ctx: *mut c_void,
    ) -> Self {
        Self {
            struct_size: size_of::<CInstallRequest>(),

            packages: packages.as_ptr(),
            packages_count: packages.len(),
            repo_path: CSlice::from_str(repo_path),
            root_path: CSlice::from_str(root_path),
            db_path: CSlice::from_str(db_path),
            branch: CSlice::from_str(branch),
            prefix_directory: CSlice::from_str(prefix_directory),
            max_retries,
            on_progress,
            progress_ctx,
        }
    }
}

pub type CInstallProgressFn =
    unsafe extern "C" fn(event: u8, package_name: CSlice, ctx: *mut c_void);

// Data container for the uninstallation operation: list of package names and repository settings
#[repr(C)]
pub struct CUninstallRequest {
    struct_size: usize,

    package_names: *const CSlice,
    package_names_len: usize,

    repo_path: CSlice,
    root_path: CSlice,
    db_path: CSlice,

    branch: CSlice,
    prefix_directory: CSlice,

    on_progress: Option<CUninstallProgressFn>,
    progress_ctx: *mut c_void,

    max_retries: u8,
}

impl CUninstallRequest {
    pub fn new(
        package_names: &[CSlice],
        repo_path: &str,
        root_path: &str,
        db_path: &str,
        branch: &str,
        prefix_directory: &str,
        max_retries: u8,
        on_progress: Option<CUninstallProgressFn>,
        progress_ctx: *mut c_void,
    ) -> Self {
        Self {
            struct_size: size_of::<CUninstallRequest>(),

            package_names: package_names.as_ptr(),
            package_names_len: package_names.len(),
            repo_path: CSlice::from_str(repo_path),
            root_path: CSlice::from_str(root_path),
            db_path: CSlice::from_str(db_path),
            branch: CSlice::from_str(branch),
            prefix_directory: CSlice::from_str(prefix_directory),
            max_retries,
            on_progress,
            progress_ctx,
        }
    }
}

pub type CUninstallProgressFn =
    unsafe extern "C" fn(event: u8, package_name: CSlice, ctx: *mut c_void);

// Data container for the rollback operation: paths and repository settings
#[repr(C)]
pub struct CRollbackRequest {
    struct_size: usize,

    root_path: CSlice,
    repo_path: CSlice,

    branch: CSlice,
    prefix_directory: CSlice,

    commit_hash: CSlice,
}

impl CRollbackRequest {
    pub fn new(
        root_path: &str,
        repo_path: &str,
        branch: &str,
        prefix_directory: &str,
        commit_hash: &str,
    ) -> Self {
        Self {
            struct_size: size_of::<CRollbackRequest>(),

            root_path: CSlice::from_str(root_path),
            repo_path: CSlice::from_str(repo_path),
            branch: CSlice::from_str(branch),
            prefix_directory: CSlice::from_str(prefix_directory),
            commit_hash: CSlice::from_str(commit_hash),
        }
    }
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
    struct_size: usize,

    path: CSlice,
    kind: CDiffKind,
}

impl CDiffEntry {
    pub fn new(path: &str, kind: CDiffKind) -> Self {
        Self {
            struct_size: size_of::<CDiffEntry>(),

            path: CSlice::from_str(path),
            kind,
        }
    }
}

impl Validate for CDiffEntry {
    fn validate(&self) -> Result<()> {
        if self.struct_size != size_of::<CDiffEntry>() {
            return Err(anyhow::anyhow!("CDiffEntry: abi mismatch"));
        }
        self.path.validate()?;
        Ok(())
    }
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
    struct_size: usize,

    pub name: CSlice,
    pub kind: CPackageDiffKind,
}

impl CPackageDiffEntry {
    pub fn new(name: &str, kind: CPackageDiffKind) -> Self {
        Self {
            struct_size: size_of::<CPackageDiffEntry>(),

            name: CSlice::from_str(name),
            kind,
        }
    }
}

impl Validate for CPackageDiffEntry {
    fn validate(&self) -> Result<()> {
        if self.struct_size != size_of::<CPackageDiffEntry>() {
            return Err(anyhow::anyhow!("CPackageDiffEntry: abi mismatch"));
        }
        self.name.validate()?;
        Ok(())
    }
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
    struct_size: usize,

    pub path: CSlice,
    pub kind: CDiffKind,
    pub package_name: CSlice,
}

impl CAttributedDiffEntry {
    pub fn new(path: &str, package_name: &str, kind: CDiffKind) -> Self {
        Self {
            struct_size: size_of::<CAttributedDiffEntry>(),

            path: CSlice::from_str(path),
            kind,
            package_name: CSlice::from_str(package_name),
        }
    }
}

impl Validate for CAttributedDiffEntry {
    fn validate(&self) -> Result<()> {
        if self.struct_size != size_of::<CAttributedDiffEntry>() {
            return Err(anyhow::anyhow!("CAttributedDiffEntry: abi mismatch"));
        }
        self.path.validate()?;
        self.package_name.validate()?;
        Ok(())
    }
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
    struct_size: usize,

    pub checksum: CSlice,
    pub subject: CSlice,
}

impl CCommitEntry {
    pub fn new(checksum: &str, subject: &str) -> Self {
        Self {
            struct_size: size_of::<CCommitEntry>(),

            checksum: CSlice::from_str(checksum),
            subject: CSlice::from_str(subject),
        }
    }
}

impl Validate for CCommitEntry {
    fn validate(&self) -> Result<()> {
        if self.struct_size != size_of::<CCommitEntry>() {
            return Err(anyhow::anyhow!("CCommitEntry: abi mismatch"));
        }
        self.checksum.validate()?;
        self.subject.validate()?;
        Ok(())
    }
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
    struct_size: usize,

    repo_path: CSlice,
    root_path: CSlice,

    prefix_directory: CSlice,
    addition_prefixes: CSliceArray,

    repo_mode: CRepoMode,
    branch: CSlice,
}

impl CInitRequest {
    pub fn new(
        repo_path: &str,
        root_path: &str,
        prefix_directory: &str,
        addition_prefixes: CSliceArray,
        repo_mode: CRepoMode,
        branch: &str,
    ) -> Self {
        Self {
            struct_size: size_of::<CInitRequest>(),

            repo_path: CSlice::from_str(repo_path),
            root_path: CSlice::from_str(root_path),
            prefix_directory: CSlice::from_str(prefix_directory),
            addition_prefixes,
            repo_mode,
            branch: CSlice::from_str(branch),
        }
    }
}

// Change type for the repository mode (archive, bare, bare-user)
#[repr(u8)]
#[derive(Clone, Copy)]
pub enum CRepoMode {
    Archive = 0,
    Bare = 1,
    BareUser = 2,
}
