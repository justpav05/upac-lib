// ── Imports ─────────────────────────────────────────────────────────────────
use anyhow::{bail, Result};

use indicatif::ProgressBar;

use std::ffi::c_void;
use std::mem::MaybeUninit;

use libloading::{Library, Symbol};

use crate::ffi::{CPackageMeta, CSlice};

// ── Types ──────────────────────────────────────────────────────────────────────
#[repr(u8)]
pub enum BackendProgressEvent {
    Verifying = 0,
    Extracting = 1,
    ReadingMeta = 2,
    SpecialStep = 3,

    Ready = 4,
    Failed = 5,
}

// Internal representation of package metadata on the Rust side
#[derive(Debug)]
pub struct PackageMeta {
    pub name: String,
    pub version: String,
    pub size: u32,
    pub architecture: String,
    pub author: String,
    pub description: String,
    pub license: String,
    pub url: String,
    pub packager: String,
    pub installed_at: i64,
    pub checksum: String,
}

impl PackageMeta {
    // Converts the PackageMeta struct to a C-compatible struct for FFI calls
    pub fn as_c(&self) -> CPackageMeta {
        CPackageMeta {
            name: CSlice::from_str(&self.name),
            version: CSlice::from_str(&self.version),
            size: self.size,
            architecture: CSlice::from_str(&self.architecture),
            author: CSlice::from_str(&self.author),
            description: CSlice::from_str(&self.description),
            license: CSlice::from_str(&self.license),
            url: CSlice::from_str(&self.url),
            packager: CSlice::from_str(&self.packager),
            installed_at: self.installed_at,
            checksum: CSlice::from_str(&self.checksum),
            _padding: 0,
        }
    }
}

// ── Backend Definition ────────────────────────────────────────
// Represents the type of backend (ALPM, RPM, DEB) for a package
#[derive(Debug, Clone, PartialEq)]
pub enum BackendKind {
    Alpm,
    Rpm,
    Deb,
}

impl BackendKind {
    // Automatically determines the package type (ALPM, RPM, DEB) based on the file extension
    pub fn detect(path: &str) -> Option<Self> {
        if path.ends_with(".pkg.tar.zst")
            || path.ends_with(".pkg.tar.xz")
            || path.ends_with(".pkg.tar.gz")
        {
            return Some(Self::Alpm);
        }
        if path.ends_with(".rpm") {
            return Some(Self::Rpm);
        }
        if path.ends_with(".deb") {
            return Some(Self::Deb);
        }
        None
    }

    // Parses a string flag (e.g., "arch", "rpm", "deb") into a BackendKind
    pub fn from_flag(string: &str) -> Result<Self> {
        match string {
            "arch" => Ok(Self::Alpm),
            "rpm" => Ok(Self::Rpm),
            "deb" => Ok(Self::Deb),
            _ => bail!("unknown backend: '{string}'. Available: alpm, rpm, deb"),
        }
    }

    // Returns the name of the shared object file for this backend (e.g., "libupac-alpm.so")
    pub fn so_name(&self) -> &'static str {
        match self {
            Self::Alpm => "libupac-alpm.so",
            Self::Rpm => "libupac-rpm.so",
            Self::Deb => "libupac-deb.so",
        }
    }
}

// ── Wrapper for the backend .so ───────────────────────────────────────────────────
// Represents the request struct for the backend's prepare function
#[repr(C)]
pub struct CPrepareRequest {
    pub struct_size: usize,

    pub pkg_path: CSlice,
    pub temp_dir: CSlice,
    pub checksum: CSlice,

    pub on_progress: Option<unsafe extern "C" fn(BackendProgressEvent, CSlice, *mut c_void)>,
    pub progress_ctx: *mut c_void,
}

// A wrapper for dynamically loading libupac.so and mapping its C functions to Rust types
pub struct Backend {
    _lib: Library,

    pub upac_backend_prepare:
        unsafe extern "C" fn(*const CPrepareRequest, *mut CPackageMeta, *mut CSlice) -> i32,
    pub upac_backend_meta_free: unsafe extern "C" fn(*mut CPackageMeta),
    pub upac_backend_cleanup: unsafe extern "C" fn(CSlice),
}

impl Backend {
    // Loads the library from a file and initializes pointers to symbols
    pub fn load(kind: &BackendKind) -> Result<Self> {
        let lib = unsafe { Library::new(kind.so_name()) }
            .map_err(|err| anyhow::anyhow!("failed to load {}: {err}", kind.so_name()))?;

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
            upac_backend_prepare: sym!("upac_backend_prepare"),
            upac_backend_meta_free: sym!("upac_backend_meta_free"),
            upac_backend_cleanup: sym!("upac_backend_cleanup"),

            _lib: lib,
        })
    }

    // Prepares a package by calling the backend's prepare function
    pub fn meta_prepare(
        &self,
        pkg_path: &str,
        temp_dir: &str,
        checksum: &str,
        on_progress: Option<unsafe extern "C" fn(BackendProgressEvent, CSlice, *mut c_void)>,
        progress_ctx: *mut c_void,
    ) -> Result<(PackageMeta, String)> {
        let req = CPrepareRequest {
            struct_size: std::mem::size_of::<CPrepareRequest>(),
            pkg_path: CSlice::from_str(pkg_path),
            temp_dir: CSlice::from_str(temp_dir),
            checksum: CSlice::from_str(checksum),
            on_progress,
            progress_ctx,
        };

        let mut package_meta_out = MaybeUninit::<CPackageMeta>::uninit();
        let mut temp_path_out = MaybeUninit::<CSlice>::uninit();

        let code = unsafe {
            (self.upac_backend_prepare)(
                &req,
                package_meta_out.as_mut_ptr(),
                temp_path_out.as_mut_ptr(),
            )
        };
        if code != 0 {
            anyhow::bail!("Backend prepare failed with code {code}");
        }

        let mut package_meta_c = unsafe { package_meta_out.assume_init() };
        let package_temp_path_c = unsafe { temp_path_out.assume_init() };

        let package_meta = unsafe {
            PackageMeta {
                name: package_meta_c.name.as_str().to_owned(),
                version: package_meta_c.version.as_str().to_owned(),
                size: package_meta_c.size as u32,
                architecture: package_meta_c.architecture.as_str().to_owned(),
                author: package_meta_c.author.as_str().to_owned(),
                description: package_meta_c.description.as_str().to_owned(),
                license: package_meta_c.license.as_str().to_owned(),
                url: package_meta_c.url.as_str().to_owned(),
                packager: package_meta_c.packager.as_str().to_owned(),
                installed_at: package_meta_c.installed_at,
                checksum: package_meta_c.checksum.as_str().to_owned(),
            }
        };
        let package_temp_path = unsafe { package_temp_path_c.as_str().to_owned() };

        unsafe { (self.upac_backend_meta_free)(&mut package_meta_c) };

        Ok((package_meta, package_temp_path))
    }
}

pub unsafe extern "C" fn on_backend_progress(
    event: BackendProgressEvent,
    detail_c: CSlice,
    ctx: *mut c_void,
) {
    if ctx.is_null() {
        return;
    }
    let progress_bar = &*(ctx as *const ProgressBar);
    let detail = detail_c.as_str();

    match event {
        BackendProgressEvent::Verifying => {
            progress_bar.set_message(format!("Verifying {}...", detail))
        }
        BackendProgressEvent::Extracting => {
            progress_bar.set_message(format!("Extracting {}...", detail))
        }
        BackendProgressEvent::ReadingMeta => progress_bar.set_message("Reading metadata..."),
        BackendProgressEvent::SpecialStep => progress_bar.set_message(detail.to_string()),
        BackendProgressEvent::Ready => progress_bar.set_message("Ready"),
        BackendProgressEvent::Failed => progress_bar.set_message("Failed"),
    }
}

// An RAII wrapper that automatically calls the library initialization upon exiting the scope
pub struct BackendLibGuard {
    lib: Backend,
}

// Loads the library and wraps it in a Guard for automatic resource management
impl BackendLibGuard {
    pub fn load(kind: &BackendKind) -> Result<Self> {
        Ok(Self {
            lib: Backend::load(kind)?,
        })
    }
}

// Allows using BackendLibGuard just like the UpacLib structure itself, via dereferencing
impl std::ops::Deref for BackendLibGuard {
    type Target = Backend;
    fn deref(&self) -> &Self::Target {
        &self.lib
    }
}
