use anyhow::{Result, bail};

use libloading::{Library, Symbol};

use std::ptr;
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

    pub fn empty() -> Self {
        Self {
            ptr: ptr::null(),
            len: 0,
        }
    }

    pub unsafe fn as_str(&self) -> &str {
        let slice = slice::from_raw_parts(self.ptr, self.len);
        str::from_utf8_unchecked(slice)
    }
}

#[repr(C)]
pub struct CSliceArray {
    pub ptr: *mut CSlice,
    pub len: usize,
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
pub struct CPackageFiles {
    pub name: CSlice,
    pub paths: CSliceArray,
}

#[repr(C)]
pub struct CInstallRequest {
    pub meta: CPackageMeta,
    pub root_path: CSlice,
    pub repo_path: CSlice,
    pub package_path: CSlice,
    pub db_path: CSlice,
    pub max_retries: u8,
}

#[repr(C)]
pub struct CSystemPaths {
    pub ostree_path: CSlice,
    pub repo_path: CSlice,
    pub db_path: CSlice,
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

    pub db_add_package: unsafe extern "C" fn(CSlice, CPackageMeta, CPackageFiles) -> i32,
    pub db_remove_package: unsafe extern "C" fn(CSlice, CSlice) -> i32,
    pub db_get_meta: unsafe extern "C" fn(CSlice, CSlice, *mut CPackageMeta) -> i32,
    pub db_get_files: unsafe extern "C" fn(CSlice, CSlice, *mut CPackageFiles) -> i32,
    pub db_list_packages: unsafe extern "C" fn(CSlice, *mut CSliceArray) -> i32,
    pub meta_free: unsafe extern "C" fn(*mut CPackageMeta),
    pub list_free: unsafe extern "C" fn(*mut CSliceArray),
    pub files_free: unsafe extern "C" fn(*mut CPackageFiles),

    pub install: unsafe extern "C" fn(CInstallRequest) -> i32,

    pub ostree_rollback: unsafe extern "C" fn(CSlice, CSlice, CSlice) -> i32,

    pub init_system: unsafe extern "C" fn(CSystemPaths, CRepoMode) -> i32,
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
            db_add_package: sym!(b"upac_db_add_package"),
            db_remove_package: sym!(b"upac_db_remove_package"),
            db_get_meta: sym!(b"upac_db_get_meta"),
            db_get_files: sym!(b"upac_db_get_files"),
            db_list_packages: sym!(b"upac_db_list_packages"),
            meta_free: sym!(b"upac_meta_free"),
            list_free: sym!(b"upac_list_free"),
            files_free: sym!(b"upac_files_free"),
            install: sym!(b"upac_install"),
            ostree_rollback: sym!(b"upac_ostree_rollback"),
            init_system: sym!(b"upac_init_system"),
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
            10 => "lock would block — another process is running",
            20 => "database: missing field",
            21 => "database: missing section",
            22 => "database: invalid entry",
            23 => "database: parse error",
            30 => "installer: copy failed",
            31 => "installer: link failed",
            32 => "installer: permissions failed",
            33 => "installer: registration failed",
            40 => "ostree: failed to open repository",
            41 => "ostree: commit failed",
            42 => "ostree: diff failed",
            43 => "ostree: rollback failed",
            44 => "ostree: no previous commit",
            50 => "already initialized",
            51 => "failed to create directory",
            52 => "ostree: init failed",
            _ => "unknown error",
        };
        bail!("{context}: {msg} (code {code})");
    }
}
