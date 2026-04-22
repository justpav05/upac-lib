// ── Imports ─────────────────────────────────────────────────────────────────
use anyhow::{bail, Result};

use libloading::{Library, Symbol};

use std::str;

use crate::ffi::{
    CAttributedDiffArray, CCommitArray, CInitRequest, CInstallRequest, CPackageDiffArray,
    CRollbackRequest, CSlice, CUninstallRequest,
};

// ── Wrapper around libupac.so ────────────────────────────────────────────────────
// A wrapper for dynamically loading libupac.so and mapping its C functions to Rust types
pub struct UpacLib {
    _lib: Library,

    // pub list_packages: unsafe extern "C" fn(CSlice, CSlice, CSlice, *mut CPackageMetaArray) -> i32,
    //pub packages_free: unsafe extern "C" fn(*mut CPackageMetaArray),
    pub install: unsafe extern "C" fn(CInstallRequest) -> i32,
    pub uninstall: unsafe extern "C" fn(CUninstallRequest) -> i32,
    pub rollback: unsafe extern "C" fn(CRollbackRequest) -> i32,

    pub diff_packages: unsafe extern "C" fn(CSlice, CSlice, CSlice, *mut CPackageDiffArray) -> i32,
    pub diff_packages_free: unsafe extern "C" fn(*mut CPackageDiffArray),
    pub diff_files_attributed: unsafe extern "C" fn(
        CSlice,
        CSlice,
        CSlice,
        CSlice,
        CSlice,
        *mut CAttributedDiffArray,
    ) -> i32,
    pub diff_files_attributed_free: unsafe extern "C" fn(*mut CAttributedDiffArray),

    pub list_commits: unsafe extern "C" fn(CSlice, CSlice, *mut CCommitArray) -> i32,
    pub commits_free: unsafe extern "C" fn(*mut CCommitArray),

    pub init: unsafe extern "C" fn(CInitRequest) -> i32,

    pub deinit: unsafe extern "C" fn(),
}

impl UpacLib {
    // Loads the library from a file and initializes pointers to symbols
    pub fn load() -> Result<Self> {
        let lib = unsafe { Library::new("libupac.so") }
            .map_err(|err| anyhow::anyhow!("failed to load libupac.so: {err}"))?;

        macro_rules! sym {
            ($name:literal) => {
                unsafe {
                    let symbol: Symbol<_> = lib.get($name).map_err(|err| {
                        anyhow::anyhow!("symbol {} not found: {err}", stringify!($name))
                    })?;
                    *symbol
                }
            };
        }

        Ok(Self {
            //list_packages: sym!(b"upac_list_packages"),
            //packages_free: sym!(b"upac_packages_free"),
            install: sym!(b"upac_install"),
            uninstall: sym!(b"upac_uninstall"),
            rollback: sym!(b"upac_rollback"),

            diff_packages: sym!(b"upac_diff_packages"),
            diff_packages_free: sym!(b"upac_diff_packages_free"),
            diff_files_attributed: sym!(b"upac_diff_files_attributed"),
            diff_files_attributed_free: sym!(b"upac_diff_files_attributed_free"),

            list_commits: sym!(b"upac_list_commits"),
            commits_free: sym!(b"upac_commits_free"),

            init: sym!(b"upac_init"),

            deinit: sym!(b"upac_deinit"),

            _lib: lib,
        })
    }

    // Converts numeric error codes from the C-layer into human-readable anyhow::Result values
    pub fn check(code: i32, context: &str) -> Result<()> {
        if code == 0 {
            return Ok(());
        }
        let msg = match code {
            1 => "unexpected error",
            2 => "out of memory",
            3 => "file not found",
            4 => "permission_denied",
            5 => "invalid path",
            6 => "no space left",
            7 => "abi_mismatch",

            9 => "thread error",
            10 => "lock would block — another process is running",
            11 => "allocz_failed",
            12 => "cancelled",
            13 => "max_retries_exceeded",
            14 => "read_failed",
            15 => "write_failed",

            20 => "database: missing field",
            21 => "database: missing section",
            22 => "database: invalid entry",
            23 => "database: parse error",
            24 => "database: write database failed",
            25 => "db_malformed_meta",
            26 => "db_malformed_files",
            27 => "idx_malformed_entry",

            30 => "package already installed",
            31 => "install: package temp path not found",
            32 => "install: checksum calculation failed",
            33 => "install: checkout failed",
            34 => "install: install cancelled",
            35 => "install: max retries exceeded",
            36 => "install_check_space_failed",
            37 => "install_make_failed",

            40 => "package not found for uninstall",
            41 => "uninstall failed",
            42 => "uninstall_file_map_corrupted",
            43 => "uninstall_staging_not_cleaned",

            50 => "ostree: failed to open repository",
            51 => "ostree: transaction failed",
            52 => "ostree: commit failed",
            53 => "ostree: diff failed",
            54 => "ostree: rollback failed",
            55 => "ostree: no previous commit",
            56 => "ostree: staging checkout failed",
            57 => "ostree: atomic swap failed (renameat2)",
            58 => "ostree: commit not found",
            59 => "ostree: cleanup failed",
            65 => "ostree: repo write failed",
            66 => "ostree: mtree insert failed",

            60 => "already initialized",
            61 => "failed to create directory",
            62 => "ostree: init failed",
            63 => "ostree: init failed",
            64 => "directory not empty",
            67 => "init prefix not found",
            68 => "init additional prefix not found",

            70 => "file checksum failed",
            71 => "file already exists",

            _ => "unknown error",
        };
        bail!("{context}: {msg} (code {code})");
    }
}

// An RAII wrapper that automatically calls the library initialization upon exiting the scope
pub struct UpacLibGuard {
    lib: UpacLib,
}

// Loads the library and wraps it in a Guard for automatic resource management
impl UpacLibGuard {
    pub fn load() -> Result<Self> {
        Ok(Self {
            lib: UpacLib::load()?,
        })
    }
}

// Allows using UpacLibGuard just like the UpacLib structure itself, via dereferencing
impl std::ops::Deref for UpacLibGuard {
    type Target = UpacLib;
    fn deref(&self) -> &Self::Target {
        &self.lib
    }
}

// Automatically calls the library deinitialization when the guard is dropped
impl Drop for UpacLibGuard {
    fn drop(&mut self) {
        unsafe { (self.lib.deinit)() };
    }
}
