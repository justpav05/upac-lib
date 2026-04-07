use anyhow::{bail, Result};

use libloading::{Library, Symbol};

use std::slice;
use std::str;

// ── Типы совпадающие с Zig ABI ────────────────────────────────────────────────
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

// ── Запросы ───────────────────────────────────────────────────────────────────
#[repr(C)]
pub struct CInstallRequest {
    pub meta: CPackageMeta,

    pub package_temp_path: CSlice,
    pub package_checksum: CSlice,

    pub repo_path: CSlice,
    pub root_path: CSlice,
    pub db_path: CSlice,

    pub branch: CSlice,

    pub max_retries: u8,
}

#[repr(C)]
pub struct CUninstallRequest {
    pub package_name: CSlice,

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

#[repr(u8)]
#[derive(Clone, Copy)]
pub enum CRepoMode {
    Archive = 0,
    Bare = 1,
    BareUser = 2,
}

// ── Обёртка над libupac.so ────────────────────────────────────────────────────
pub struct UpacLib {
    _lib: Library,

    pub install: unsafe extern "C" fn(CInstallRequest) -> i32,
    pub uninstall: unsafe extern "C" fn(CUninstallRequest) -> i32,
    pub rollback: unsafe extern "C" fn(CRollbackRequest) -> i32,

    pub diff: unsafe extern "C" fn(CSlice, CSlice, CSlice, *mut CDiffArray) -> i32,
    pub diff_free: unsafe extern "C" fn(*mut CDiffArray),

    pub list_commits: unsafe extern "C" fn(CSlice, CSlice, *mut CCommitArray) -> i32,
    pub commits_free: unsafe extern "C" fn(*mut CCommitArray),

    pub init: unsafe extern "C" fn(CSystemPaths, CRepoMode) -> i32,

    pub free: unsafe extern "C" fn(*mut u8, usize),
    pub deinit: unsafe extern "C" fn(),
}

impl UpacLib {
    pub fn load() -> Result<Self> {
        let lib = unsafe { Library::new("libupac.so") }
            .map_err(|err| anyhow::anyhow!("failed to load libupac.so: {err}"))?;

        macro_rules! sym {
            ($name:literal) => {
                unsafe {
                    let s: Symbol<_> = lib.get($name).map_err(|err| {
                        anyhow::anyhow!("symbol {} not found: {err}", stringify!($name))
                    })?;
                    *s
                }
            };
        }

        Ok(Self {
            install: sym!(b"upac_install"),
            uninstall: sym!(b"upac_uninstall"),
            rollback: sym!(b"upac_rollback"),

            diff: sym!(b"upac_diff"),
            diff_free: sym!(b"upac_diff_free"),

            list_commits: sym!(b"upac_list_commits"),
            commits_free: sym!(b"upac_commits_free"),

            init: sym!(b"upac_init"),

            free: sym!(b"upac_free"),
            deinit: sym!(b"upac_deinit"),

            _lib: lib,
        })
    }

    pub fn check(code: i32, context: &str) -> Result<()> {
        if code == 0 {
            return Ok(());
        }
        let msg = match code {
            1 => "unexpected error",
            2 => "out of memory",
            3 => "invalid path",
            4 => "file not found",
            5 => "access denied",

            10 => "lock would block — another process is running",

            20 => "database: missing field",
            21 => "database: missing section",
            22 => "database: invalid entry",
            23 => "database: parse error",

            30 => "package already installed",
            31 => "install failed",

            40 => "package not found for uninstall",
            41 => "uninstall failed",

            50 => "ostree: failed to open repository",
            51 => "ostree: commit failed",
            52 => "ostree: diff failed",
            53 => "ostree: rollback failed",
            54 => "ostree: no previous commit",

            60 => "already initialized",
            61 => "failed to create directory",
            62 => "ostree: init failed",
            _ => "unknown error",
        };
        bail!("{context}: {msg} (code {code})");
    }
}
