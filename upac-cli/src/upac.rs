// ── Imports ─────────────────────────────────────────────────────────────────
use anyhow::{bail, Result};

use libloading::{Library, Symbol};

use std::str;

use crate::ffi::{
    CAttributedDiffArray, CCommitArray, CInitRequest, CInstallRequest, CPackageDiffArray,
    CPackageMetaArray, CRollbackRequest, CSlice, CUninstallRequest,
};

// ── Wrapper around libupac.so ────────────────────────────────────────────────────
pub struct UpacLib {
    _lib: Library,

    pub list_packages: unsafe extern "C" fn(CSlice, CSlice, CSlice, *mut CPackageMetaArray) -> i32,
    pub packages_free: unsafe extern "C" fn(*mut CPackageMetaArray),

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
            list_packages: sym!(b"upac_list_packages"),
            packages_free: sym!(b"upac_packages_free"),

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
            32 => "install: package temp path not found",
            33 => "install: repository path not found",
            34 => "install: checksum calculation failed",
            35 => "install: failed to write object to ostree repo",
            36 => "install: failed to insert file into mutable tree",
            37 => "install: file object already exists in repo",

            40 => "package not found for uninstall",
            41 => "uninstall failed",

            50 => "ostree: failed to open repository",
            51 => "ostree: commit failed",
            52 => "ostree: diff failed",
            53 => "ostree: rollback failed",
            54 => "ostree: no previous commit",
            55 => "ostree: staging checkout failed",
            56 => "ostree: atomic swap failed (renameat2)",

            60 => "already initialized",
            61 => "failed to create directory",
            62 => "ostree: init failed",
            _ => "unknown error",
        };
        bail!("{context}: {msg} (code {code})");
    }
}

pub struct UpacLibGuard {
    lib: UpacLib,
}

impl UpacLibGuard {
    pub fn load() -> Result<Self> {
        Ok(Self {
            lib: UpacLib::load()?,
        })
    }
}

impl std::ops::Deref for UpacLibGuard {
    type Target = UpacLib;
    fn deref(&self) -> &Self::Target {
        &self.lib
    }
}

impl Drop for UpacLibGuard {
    fn drop(&mut self) {
        unsafe { (self.lib.deinit)() };
    }
}
