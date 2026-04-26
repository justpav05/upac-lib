// ── Imports ─────────────────────────────────────────────────────────────────
use anyhow::{bail, Result};

use libloading::Library;

use std::ffi::c_void;
use std::str;

use crate::ffi::{
    CAttributedDiffArray, CCommitArray, CInitRequest, CInstallRequest, CPackageDiffArray,
    CRollbackRequest, CSlice, CUninstallRequest,
};
use crate::types::BackendKind;

// ── Wrapper around libupac.so ────────────────────────────────────────────────────
// A wrapper for dynamically loading libupac.so and mapping its C functions to Rust types
pub struct UpacLib {
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

    pub list_packages: unsafe extern "C" fn(CSlice, CSlice, CSlice, *mut *mut c_void) -> i32,
    pub packages_free: unsafe extern "C" fn(*mut c_void),
    pub packages_count: unsafe extern "C" fn(*mut c_void) -> usize,

    pub package_get_slice_field: unsafe extern "C" fn(*mut c_void, usize, u8, *mut CSlice) -> i32,
    pub package_get_int_field: unsafe extern "C" fn(*mut c_void, usize, u8, *mut u32) -> i32,

    pub list_commits: unsafe extern "C" fn(CSlice, CSlice, *mut CCommitArray) -> i32,
    pub commits_free: unsafe extern "C" fn(*mut CCommitArray),

    pub init: unsafe extern "C" fn(CInitRequest) -> i32,

    pub deinit: unsafe extern "C" fn(),

    _lib: Library,
}

impl UpacLib {
    // Loads the library from a file and initializes pointers to symbols
    unsafe fn load_symbol<T: Copy>(library: &Library, symbol_name: &str) -> Result<T> {
        library
            .get(symbol_name.as_bytes())
            .map(|symbol| *symbol)
            .map_err(|error| anyhow::anyhow!("Symbol {symbol_name} not found: {error}"))
    }

    // Loads the library from a file and initializes pointers to symbols
    pub fn load(backend_kind: &BackendKind) -> Result<Self> {
        let loaded_library = unsafe { Library::new(backend_kind.so_name()) }.map_err(|error| {
            anyhow::anyhow!("Failed to load {}: {error}", backend_kind.so_name())
        })?;

        Ok(Self {
            install: unsafe { Self::load_symbol(&loaded_library, "install")? },
            uninstall: unsafe { Self::load_symbol(&loaded_library, "uninstall")? },
            rollback: unsafe { Self::load_symbol(&loaded_library, "rollback")? },

            diff_packages: unsafe { Self::load_symbol(&loaded_library, "diff_packages")? },
            diff_packages_free: unsafe {
                Self::load_symbol(&loaded_library, "diff_packages_free")?
            },
            diff_files_attributed: unsafe {
                Self::load_symbol(&loaded_library, "diff_files_attributed")?
            },
            diff_files_attributed_free: unsafe {
                Self::load_symbol(&loaded_library, "diff_files_attributed_free")?
            },

            list_packages: unsafe { Self::load_symbol(&loaded_library, "list_packages")? },
            packages_free: unsafe { Self::load_symbol(&loaded_library, "packages_free")? },
            packages_count: unsafe { Self::load_symbol(&loaded_library, "packages_count")? },

            package_get_slice_field: unsafe {
                Self::load_symbol(&loaded_library, "package_get_slice_field")?
            },
            package_get_int_field: unsafe {
                Self::load_symbol(&loaded_library, "package_get_int_field")?
            },

            list_commits: unsafe { Self::load_symbol(&loaded_library, "list_commits")? },
            commits_free: unsafe { Self::load_symbol(&loaded_library, "commits_free")? },

            init: unsafe { Self::load_symbol(&loaded_library, "init")? },
            deinit: unsafe { Self::load_symbol(&loaded_library, "deinit")? },

            _lib: loaded_library,
        })
    }

    // Converts numeric error codes from the C-layer into human-readable anyhow::Result values
    pub fn check(code: i32, context: &str) -> Result<()> {
        let message = match code {
            0 => return Ok(()),

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
            12 => return Err(anyhow::anyhow!("{context}: cancelled (code {code})")),
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
            36 => "install: check space failed",
            37 => "install: make failed",

            40 => "package not found for uninstall",
            41 => "uninstall failed",
            42 => "uninstall: file map corrupted",
            43 => "uninstall: staging not cleaned",

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
        bail!("{context}: {message} (code {code})");
    }
}
