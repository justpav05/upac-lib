// SPDX-FileCopyrightText: 2026 JustPav
// SPDX-FileCopyrightText: 2026 SmoothTeam
//
// SPDX-License-Identifier: GPL-3.0-only

use anyhow::Result;

use i18n_embed_fl::fl;

use nix::unistd::Uid;

use upac_abi::LIB_ABI_VERSION;
use upac_abi::error::CError;
use upac_abi::hook::CancelToken;
use upac_abi::request::{
    CCommitRequest, CDiffConfigRequest, CDiffPackagesRequest, CDiffPrefixRequest, CDiffRequest, CFilesRequest,
    CGcRequest, CInstallRequest, CListConfigRequest, CListHistoryRequest, CListPackagesRequest, CListPrefixRequest,
    CMimeSyncRequest, CPinRequest, CRollbackRequest, CSearchFilesRequest, CSearchInMetaRequest,
    CSearchInPackageFilesRequest, CSearchMetaRequest, CUninstallRequest, CUpdateRequest,
};
use upac_abi::response::{
    CDiffConfigResponse, CDiffPackagesResponse, CDiffPrefixResponse, CDiffResponse, CListConfigResponse,
    CListHistoryResponse, CListPackagesResponse, CListPrefixResponse, CSearchFilesResponse, CSearchInMetaResponse,
    CSearchInPackageFilesResponse, CSearchMetaResponse,
};

#[cfg(feature = "dynamic-plugins")]
use libloading::Library;

use super::types::errors::{AbiMismatch, LibError};

use crate::locale::LOADER;

#[cfg(test)]
#[path = "../tests/inline/libcore.rs"]
mod tests;

#[cfg(feature = "static-link")]
use upac::export::mutated::{
    commit::commit, files::files, gc::gc, installer::install, mime::mime, pin::pin_deploy, rollback::rollback,
    uninstaller::uninstall, update::update,
};
#[cfg(feature = "static-link")]
use upac::export::unmutated::{
    diff::diff, diff_config::diff_config, diff_packages::diff_packages, diff_prefix::diff_prefix,
    list_config::list_config, list_history::list_history, list_packages::list_packages, list_prefix::list_prefix,
    search_files::search_files, search_in_meta::search_in_meta, search_in_package_files::search_in_package_files,
    search_meta::search_meta,
};
#[cfg(feature = "static-link")]
use upac::export::{cancel, version_abi};

#[cfg(feature = "static-link")]
impl RoSymbols {
    fn from_static() -> Self {
        Self {
            list_packages,
            search_meta,
            diff_packages,
            list_config,
            list_history,
            list_prefix,
            diff_prefix,
            search_files,
            diff_config,
            diff,
            search_in_meta,
            search_in_package_files,
        }
    }
}

#[cfg(feature = "static-link")]
impl RwSymbols {
    fn from_static() -> Self {
        Self {
            install,
            update,
            uninstall,
            commit,
            rollback,
            files,
            mime,
            gc,
            pin_deploy,
        }
    }
}

#[cfg(feature = "static-link")]
impl Lib {
    pub fn load() -> Result<Self> {
        let lib = Self {
            ro: RoSymbols::from_static(),
            rw: RwSymbols::from_static(),
            cancel,
            version_abi,
        };

        let abi_version = unsafe { (lib.version_abi)() };
        if abi_version != upac_abi::ABI_VERSION {
            let err = AbiMismatch {
                got: abi_version,
                expected: upac_abi::ABI_VERSION,
            };

            return Err(err.into());
        }

        Ok(lib)
    }
}

#[cfg(feature = "dynamic-plugins")]
pub trait LoadLibrarySymbols: Sized {
    fn load(lib: &Library) -> Result<Self>;
}

#[cfg(feature = "dynamic-plugins")]
impl LoadLibrarySymbols for RoSymbols {
    fn load(lib: &Library) -> Result<Self> {
        Ok(Self {
            list_packages: unsafe { Lib::load_symbol(lib, "list_packages")? },
            search_meta: unsafe { Lib::load_symbol(lib, "search_meta")? },
            diff_packages: unsafe { Lib::load_symbol(lib, "diff_packages")? },
            list_config: unsafe { Lib::load_symbol(lib, "list_config")? },
            list_history: unsafe { Lib::load_symbol(lib, "list_history")? },
            list_prefix: unsafe { Lib::load_symbol(lib, "list_prefix")? },
            diff_prefix: unsafe { Lib::load_symbol(lib, "diff_prefix")? },
            search_files: unsafe { Lib::load_symbol(lib, "search_files")? },
            diff_config: unsafe { Lib::load_symbol(lib, "diff_config")? },
            diff: unsafe { Lib::load_symbol(lib, "diff")? },
            search_in_meta: unsafe { Lib::load_symbol(lib, "search_in_meta")? },
            search_in_package_files: unsafe { Lib::load_symbol(lib, "search_in_package_files")? },
        })
    }
}

#[cfg(feature = "dynamic-plugins")]
impl LoadLibrarySymbols for RwSymbols {
    fn load(lib: &Library) -> Result<Self> {
        Ok(Self {
            install: unsafe { Lib::load_symbol(lib, "install")? },
            update: unsafe { Lib::load_symbol(lib, "update")? },
            uninstall: unsafe { Lib::load_symbol(lib, "uninstall")? },
            commit: unsafe { Lib::load_symbol(lib, "commit")? },
            rollback: unsafe { Lib::load_symbol(lib, "rollback")? },
            files: unsafe { Lib::load_symbol(lib, "files")? },
            mime: unsafe { Lib::load_symbol(lib, "mime")? },
            gc: unsafe { Lib::load_symbol(lib, "gc")? },
            pin_deploy: unsafe { Lib::load_symbol(lib, "pin_deploy")? },
        })
    }
}

#[cfg(feature = "dynamic-plugins")]
impl Lib {
    pub fn load() -> Result<Self> {
        let loaded_library = unsafe { Library::new("libupac.so") }?;

        let lib = Self {
            ro: RoSymbols::load(&loaded_library)?,
            rw: RwSymbols::load(&loaded_library)?,

            cancel: unsafe { Lib::load_symbol(&loaded_library, "cancel")? },
            version_abi: unsafe { Lib::load_symbol(&loaded_library, "version_abi")? },

            _lib: loaded_library,
        };

        let abi_version = unsafe { (lib.version_abi)() };
        if abi_version != LIB_ABI_VERSION {
            let err = AbiMismatch {
                got: abi_version,
                expected: LIB_ABI_VERSION,
            };

            return Err(err.into());
        }

        Ok(lib)
    }

    /// # Safety
    /// `T` must exactly match the signature of the C symbol `name` resolves to, and the returned value
    /// must not outlive `lib`.
    unsafe fn load_symbol<T: Copy>(lib: &Library, name: &str) -> Result<T> {
        unsafe {
            lib.get(name.as_bytes())
                .map(|symbol| *symbol)
                .map_err(|err| anyhow::anyhow!("Symbol {name} not found: {err}"))
        }
    }
}

pub struct RoSymbols {
    pub list_packages: unsafe extern "C" fn(CListPackagesRequest, *mut CListPackagesResponse, *mut CError) -> i32,
    pub search_meta: unsafe extern "C" fn(CSearchMetaRequest, *mut CSearchMetaResponse, *mut CError) -> i32,
    pub diff_packages: unsafe extern "C" fn(CDiffPackagesRequest, *mut CDiffPackagesResponse, *mut CError) -> i32,
    pub list_config: unsafe extern "C" fn(CListConfigRequest, *mut CListConfigResponse, *mut CError) -> i32,
    pub list_history: unsafe extern "C" fn(CListHistoryRequest, *mut CListHistoryResponse, *mut CError) -> i32,
    pub list_prefix: unsafe extern "C" fn(CListPrefixRequest, *mut CListPrefixResponse, *mut CError) -> i32,
    pub diff_prefix: unsafe extern "C" fn(CDiffPrefixRequest, *mut CDiffPrefixResponse, *mut CError) -> i32,
    pub search_files: unsafe extern "C" fn(CSearchFilesRequest, *mut CSearchFilesResponse, *mut CError) -> i32,
    pub diff_config: unsafe extern "C" fn(CDiffConfigRequest, *mut CDiffConfigResponse, *mut CError) -> i32,
    pub diff: unsafe extern "C" fn(CDiffRequest, *mut CDiffResponse, *mut CError) -> i32,
    pub search_in_meta: unsafe extern "C" fn(CSearchInMetaRequest, *mut CSearchInMetaResponse, *mut CError) -> i32,
    pub search_in_package_files:
        unsafe extern "C" fn(CSearchInPackageFilesRequest, *mut CSearchInPackageFilesResponse, *mut CError) -> i32,
}

pub struct RwSymbols {
    pub install: unsafe extern "C" fn(CInstallRequest, *mut CError) -> i32,
    pub update: unsafe extern "C" fn(CUpdateRequest, *mut CError) -> i32,
    pub uninstall: unsafe extern "C" fn(CUninstallRequest, *mut CError) -> i32,
    pub commit: unsafe extern "C" fn(CCommitRequest, *mut CError) -> i32,
    pub rollback: unsafe extern "C" fn(CRollbackRequest, *mut CError) -> i32,
    pub files: unsafe extern "C" fn(CFilesRequest, *mut CError) -> i32,
    pub mime: unsafe extern "C" fn(CMimeSyncRequest, *mut CError) -> i32,
    pub gc: unsafe extern "C" fn(CGcRequest, *mut CError) -> i32,
    pub pin_deploy: unsafe extern "C" fn(CPinRequest, *mut CError) -> i32,
}

pub struct Lib {
    pub ro: RoSymbols,
    pub rw: RwSymbols,

    pub cancel: unsafe extern "C" fn(*mut CancelToken),
    pub version_abi: unsafe extern "C" fn() -> u32,
    #[cfg(feature = "dynamic-plugins")]
    _lib: Library,
}

impl Lib {
    pub fn require_write(&self) -> Result<&RwSymbols> {
        if !Uid::effective().is_root() {
            anyhow::bail!(fl!(LOADER, "err-requires-root"));
        }

        Ok(&self.rw)
    }
}

impl LibError {
    /// # Safety
    /// `error` must point to a valid, initialized `CError` whenever `code != 0` — the ABI only writes
    /// to it on the failure path, leaving it uninitialized on success.
    pub unsafe fn check(code: i32, error: *const CError) -> Result<(), Self> {
        if code == 0 {
            return Ok(());
        }
        Err(Self {
            error: unsafe { *error },
        })
    }
}
