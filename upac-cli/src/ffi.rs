// ── Imports ─────────────────────────────────────────────────────────────────
use anyhow::Result;

use libloading::Library;

use std::ffi::{c_void, CStr, CString};
use std::marker::PhantomData;
use std::ptr::{null, null_mut};
use std::slice;
use std::str;

pub trait Validate {
    fn validate(&self) -> Result<()>;
}

// ── CSlice: FFI view over a null-terminated byte buffer ──────────────────────
// A (ptr, len) pair that mirrors Zig's CSlice. `ptr[len]` MUST be 0
#[repr(C)]
#[derive(Clone, Copy)]
pub struct CSlice {
    pub ptr: *const u8,
    pub len: usize,
}

impl CSlice {
    // Empty, NULL-sentinel slice. Accepted by the library for optional fields.
    pub const fn empty() -> Self {
        Self {
            ptr: null(),
            len: 0,
        }
    }

    // Construct a CSlice from an owned CString. The borrow checker ties the slice lifetime to the source CString.
    pub fn from_cstring(source: &CString) -> Self {
        let bytes = source.as_bytes();
        Self {
            ptr: bytes.as_ptr(),
            len: bytes.len(),
        }
    }

    // Construct a CSlice from a borrowed CStr (same invariant).
    pub fn from_cstr(source: &CStr) -> Self {
        let bytes = source.to_bytes();
        Self {
            ptr: bytes.as_ptr(),
            len: bytes.len(),
        }
    }

    // Returns a &str view of the CSlice, assuming valid UTF-8.
    pub unsafe fn as_str(&self) -> &str {
        let bytes = slice::from_raw_parts(self.ptr, self.len);
        str::from_utf8_unchecked(bytes)
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

// ── CArray<T>: generic output array produced by the library ──────────────────
#[repr(C)]
pub struct CArray<T> {
    pub ptr: *mut T,
    pub len: usize,
    _marker: PhantomData<T>,
}

impl<T> CArray<T> {
    pub const fn empty() -> Self {
        Self {
            ptr: null_mut(),
            len: 0,
            _marker: PhantomData,
        }
    }

    pub unsafe fn as_slice(&self) -> &[T] {
        if self.ptr.is_null() || self.len == 0 {
            &[]
        } else {
            slice::from_raw_parts(self.ptr, self.len)
        }
    }
}

// ── Package meta handle (backend-owned, opaque) ──────────────────────────────
pub type PackageMetaHandle = *mut c_void;

// ── CPackageEntry — one item in CMutatedRequest.packages ─────────────────────
#[repr(C)]
#[derive(Clone, Copy)]
pub struct CPackageEntry {
    struct_size: usize,

    meta: PackageMetaHandle,
    temp_path: CSlice,
    checksum: CSlice,
}

impl CPackageEntry {
    pub fn new(meta: PackageMetaHandle, temp_path: CSlice, checksum: CSlice) -> Self {
        Self {
            struct_size: size_of::<CPackageEntry>(),
            meta,
            temp_path,
            checksum,
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

// ── CPackageMeta — library-owned metadata record (out-parameter for list) ────
#[repr(C)]
#[derive(Clone, Copy)]
pub struct CPackageMeta {
    struct_size: usize,

    pub name: CSlice,
    pub version: CSlice,
    pub architecture: CSlice,
    pub author: CSlice,
    pub description: CSlice,
    pub license: CSlice,
    pub url: CSlice,
    pub packager: CSlice,
    pub checksum: CSlice,
    pub size: u32,
    _padding: u32,
    pub installed_at: i64,
}

// ── Progress callback ────────────────────────────────────────────────────────
// Shared signature for install / uninstall / rollback progress reporting.
pub type CProgressFn = unsafe extern "C" fn(event: u32, package_name: CSlice, ctx: *mut c_void);

// ── CRepoMode ────────────────────────────────────────────────────────────────
// Kept as a plain `u8` — the library accepts a pointer to an int and translates it into its own enum with validation. See OwnedUnmutatedRequest.
#[repr(u8)]
#[derive(Clone, Copy, Debug)]
pub enum CRepoMode {
    Archive = 0,
    Bare = 1,
    BareUser = 2,
}

// ── CMutatedRequest (raw / owned) ────────────────────────────────────────────
// Unified request used by install, uninstall and rollback.
#[repr(C)]
pub struct CMutatedRequestRaw {
    struct_size: usize,

    repo_path: CSlice,
    root_path: CSlice,
    db_path: CSlice,
    branch: CSlice,
    prefix_directory: CSlice,

    // Install
    packages: *const CPackageEntry,
    packages_count: usize,

    // Uninstall
    package_names: *const CSlice,
    package_names_len: usize,

    // Rollback
    commit_hash: CSlice,

    on_progress: Option<CProgressFn>,
    progress_ctx: *mut c_void,

    max_retries: u8,
}

pub struct CMutatedRequest {
    // Owned strings — storage for every CSlice below.
    repo_path: CString,
    root_path: CString,
    db_path: CString,
    branch: CString,
    prefix_directory: CString,
    commit_hash: Option<CString>,

    // Install: temp_path / checksum storage is kept here; CPackageEntry in `packages` references slices into these CStrings.
    package_names_storage: Vec<CString>,
    package_names_slices: Vec<CSlice>,

    packages_storage: Vec<OwnedPackageEntry>,
    packages_view: Vec<CPackageEntry>,

    on_progress: Option<CProgressFn>,
    progress_ctx: *mut c_void,
    max_retries: u8,
}

// A single install entry whose CString fields back the CSlices in CPackageEntry.
pub struct OwnedPackageEntry {
    pub meta: PackageMetaHandle,
    pub temp_path: CString,
    pub checksum: CString,
}

impl OwnedPackageEntry {
    pub fn new(meta: PackageMetaHandle, temp_path: CString, checksum: CString) -> Self {
        Self {
            meta,
            temp_path,
            checksum,
        }
    }

    fn as_c_entry(&self) -> CPackageEntry {
        CPackageEntry::new(
            self.meta,
            CSlice::from_cstring(&self.temp_path),
            CSlice::from_cstring(&self.checksum),
        )
    }
}

pub struct CMutatedRequestBuilder {
    req: CMutatedRequest,
}

impl CMutatedRequest {
    pub fn builder(
        repo_path: CString,
        root_path: CString,
        db_path: CString,
        branch: CString,
        prefix_directory: CString,
    ) -> CMutatedRequestBuilder {
        CMutatedRequestBuilder {
            req: CMutatedRequest {
                repo_path,
                root_path,
                db_path,
                branch,
                prefix_directory,
                commit_hash: None,
                package_names_storage: Vec::new(),
                package_names_slices: Vec::new(),
                packages_storage: Vec::new(),
                packages_view: Vec::new(),
                on_progress: None,
                progress_ctx: null_mut(),
                max_retries: 0,
            },
        }
    }

    // Build the #[repr(C)] view. The raw struct borrows from `self`;
    pub fn as_raw(&self) -> CMutatedRequestRaw {
        CMutatedRequestRaw {
            struct_size: size_of::<CMutatedRequestRaw>(),

            repo_path: CSlice::from_cstring(&self.repo_path),
            root_path: CSlice::from_cstring(&self.root_path),
            db_path: CSlice::from_cstring(&self.db_path),
            branch: CSlice::from_cstring(&self.branch),
            prefix_directory: CSlice::from_cstring(&self.prefix_directory),

            packages: if self.packages_view.is_empty() {
                null()
            } else {
                self.packages_view.as_ptr()
            },
            packages_count: self.packages_view.len(),

            package_names: if self.package_names_slices.is_empty() {
                null()
            } else {
                self.package_names_slices.as_ptr()
            },
            package_names_len: self.package_names_slices.len(),

            commit_hash: self
                .commit_hash
                .as_ref()
                .map(CSlice::from_cstring)
                .unwrap_or_else(CSlice::empty),

            on_progress: self.on_progress,
            progress_ctx: self.progress_ctx,
            max_retries: self.max_retries,
        }
    }
}

impl CMutatedRequestBuilder {
    pub fn packages(mut self, entries: Vec<OwnedPackageEntry>) -> Self {
        self.req.packages_view = entries.iter().map(OwnedPackageEntry::as_c_entry).collect();
        self.req.packages_storage = entries;
        self
    }

    pub fn package_names(mut self, names: Vec<CString>) -> Self {
        self.req.package_names_slices = names.iter().map(CSlice::from_cstring).collect();
        self.req.package_names_storage = names;
        self
    }

    pub fn commit_hash(mut self, hash: CString) -> Self {
        self.req.commit_hash = Some(hash);
        self
    }

    pub fn progress(mut self, cb: CProgressFn, ctx: *mut c_void) -> Self {
        self.req.on_progress = Some(cb);
        self.req.progress_ctx = ctx;
        self
    }

    pub fn max_retries(mut self, retries: u8) -> Self {
        self.req.max_retries = retries;
        self
    }

    pub fn build(self) -> CMutatedRequest {
        self.req
    }
}

// ── CUnmutatedRequest (raw / owned) ──────────────────────────────────────────
// Unified request for init / diff / list. `repo_mode` is a pointer to an int that the library interprets as CRepoMode (with validation);

#[repr(C)]
pub struct CUnmutatedRequestRaw {
    struct_size: usize,

    repo_path: CSlice,
    root_path: CSlice,
    db_path: CSlice,
    branch: CSlice,
    prefix: CSlice,

    from_commit_hash: CSlice,
    to_commit_hash: CSlice,

    repo_mode: *mut c_void,
}

pub struct CUnmutatedRequest {
    repo_path: CString,
    root_path: CString,
    db_path: CString,
    branch: CString,
    prefix: CString,

    from_commit_hash: Option<CString>,
    to_commit_hash: Option<CString>,

    // Backing storage for `repo_mode`; stored as u32 since the Zig side reads it as `*const i32` via @ptrCast
    repo_mode_storage: Option<Box<u32>>,
}

pub struct CUnmutatedRequestBuilder {
    req: CUnmutatedRequest,
}

impl CUnmutatedRequest {
    pub fn builder(
        repo_path: CString,
        root_path: CString,
        db_path: CString,
        branch: CString,
        prefix: CString,
    ) -> CUnmutatedRequestBuilder {
        CUnmutatedRequestBuilder {
            req: CUnmutatedRequest {
                repo_path,
                root_path,
                db_path,
                branch,
                prefix,
                from_commit_hash: None,
                to_commit_hash: None,
                repo_mode_storage: None,
            },
        }
    }

    pub fn as_raw(&self) -> CUnmutatedRequestRaw {
        CUnmutatedRequestRaw {
            struct_size: size_of::<CUnmutatedRequestRaw>(),

            repo_path: CSlice::from_cstring(&self.repo_path),
            root_path: CSlice::from_cstring(&self.root_path),
            db_path: CSlice::from_cstring(&self.db_path),
            branch: CSlice::from_cstring(&self.branch),
            prefix: CSlice::from_cstring(&self.prefix),

            from_commit_hash: self
                .from_commit_hash
                .as_ref()
                .map(CSlice::from_cstring)
                .unwrap_or_else(CSlice::empty),
            to_commit_hash: self
                .to_commit_hash
                .as_ref()
                .map(CSlice::from_cstring)
                .unwrap_or_else(CSlice::empty),

            repo_mode: self
                .repo_mode_storage
                .as_ref()
                .map(|b| &**b as *const u32 as *mut c_void)
                .unwrap_or(null_mut()),
        }
    }
}

impl CUnmutatedRequestBuilder {
    pub fn from_commit(mut self, hash: CString) -> Self {
        self.req.from_commit_hash = Some(hash);
        self
    }

    pub fn to_commit(mut self, hash: CString) -> Self {
        self.req.to_commit_hash = Some(hash);
        self
    }

    pub fn repo_mode(mut self, mode: CRepoMode) -> Self {
        self.req.repo_mode_storage = Some(Box::new(mode as u32));
        self
    }

    pub fn build(self) -> CUnmutatedRequest {
        self.req
    }
}

// ── Prepare request (backend) ────────────────────────────────────────────────
#[repr(C)]
pub struct CPrepareRequestRaw {
    struct_size: usize,
    checksum: CSlice,

    package_path: CSlice,
    temp_dir_path: CSlice,

    on_progress: unsafe extern "C" fn(u8, CSlice, *mut c_void),
    progress_ctx: *mut c_void,
}

pub struct CPrepareRequest {
    checksum: CString,
    package_path: CString,
    temp_dir_path: CString,

    on_progress: unsafe extern "C" fn(u8, CSlice, *mut c_void),
    progress_ctx: *mut c_void,
}

impl CPrepareRequest {
    pub fn new(
        package_path: CString,
        temp_dir_path: CString,
        checksum: CString,
        on_progress: unsafe extern "C" fn(u8, CSlice, *mut c_void),
        progress_ctx: *mut c_void,
    ) -> Self {
        Self {
            checksum,
            package_path,
            temp_dir_path,
            on_progress,
            progress_ctx,
        }
    }

    pub fn as_raw(&self) -> CPrepareRequestRaw {
        CPrepareRequestRaw {
            struct_size: size_of::<CPrepareRequestRaw>(),
            checksum: CSlice::from_cstring(&self.checksum),
            package_path: CSlice::from_cstring(&self.package_path),
            temp_dir_path: CSlice::from_cstring(&self.temp_dir_path),
            on_progress: self.on_progress,
            progress_ctx: self.progress_ctx,
        }
    }
}

// ── Diff entries ─────────────────────────────────────────────────────────────
#[repr(u8)]
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum CDiffKind {
    Added = 0,
    Removed = 1,
    Modified = 2,
}

#[repr(u8)]
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum CPackageDiffKind {
    Added = 0,
    Removed = 1,
    Updated = 2,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct CPackageDiffEntry {
    struct_size: usize,

    pub name: CSlice,
    pub kind: CPackageDiffKind,
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

#[repr(C)]
#[derive(Clone, Copy)]
pub struct CAttributedDiffEntry {
    struct_size: usize,

    pub path: CSlice,
    pub kind: CDiffKind,
    pub package_name: CSlice,
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

// ── Commit entry ─────────────────────────────────────────────────────────────
#[repr(C)]
#[derive(Clone, Copy)]
pub struct CCommitEntry {
    struct_size: usize,

    pub checksum: CSlice,
    pub subject: CSlice,
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

// ── Package meta field indices (list_packages accessors) ─────────────────────
#[repr(u8)]
#[derive(Clone, Copy)]
pub enum CPackageField {
    Name = 0,
    Version = 1,
    Architecture = 2,
    Author = 3,
    Description = 4,
    License = 5,
    Url = 6,
    Packager = 7,
    Checksum = 8,
    Size = 9,
    InstalledAt = 10,
}

// ── Symbol loader ────────────────────────────────────────────────────────────
pub unsafe fn load_symbol<T: Copy>(lib: &Library, name: &str) -> Result<T> {
    lib.get(name.as_bytes())
        .map(|symbol| *symbol)
        .map_err(|err| anyhow::anyhow!("Symbol {name} not found: {err}"))
}
