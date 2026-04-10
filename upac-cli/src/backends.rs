use anyhow::{bail, Result};

use libloading::{Library, Symbol};

use crate::ffi::{CPackageMeta, CSlice};

// ── Типы ──────────────────────────────────────────────────────────────────────
#[derive(Debug)]
pub struct PackageMeta {
    pub name: String,
    pub version: String,
    pub author: String,
    pub description: String,
    pub license: String,
    pub url: String,
    pub installed_at: i64,
    pub checksum: String,
}

impl PackageMeta {
    pub fn as_c(&self) -> CPackageMeta {
        CPackageMeta {
            name: CSlice::from_str(&self.name),
            version: CSlice::from_str(&self.version),
            author: CSlice::from_str(&self.author),
            description: CSlice::from_str(&self.description),
            license: CSlice::from_str(&self.license),
            url: CSlice::from_str(&self.url),
            installed_at: self.installed_at,
            checksum: CSlice::from_str(&self.checksum),
        }
    }
}

// ── Определение бэкенда по расширению ────────────────────────────────────────
#[derive(Debug, Clone, PartialEq)]
pub enum BackendKind {
    Alpm,
    Rpm,
    Deb,
}

impl BackendKind {
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

    pub fn from_flag(string: &str) -> Result<Self> {
        match string {
            "arch" | "alpm" => Ok(Self::Alpm),
            "rpm" | "fedora" | "opensuse" => Ok(Self::Rpm),
            "deb" | "debian" => Ok(Self::Deb),
            _ => bail!("unknown backend: '{string}'. Available: alpm, rpm, deb"),
        }
    }

    pub fn so_name(&self) -> &'static str {
        match self {
            Self::Alpm => "libupac-arch.so",
            Self::Rpm => "libupac-rpm.so",
            Self::Deb => "libupac-deb.so",
        }
    }
}

// ── Обёртка над бэкенд .so ───────────────────────────────────────────────────
#[repr(C)]
struct CPrepareRequest {
    pkg_path: CSlice,
    out_path: CSlice,
    checksum: CSlice,
}

pub struct Backend {
    _lib: Library,
    prepare: unsafe extern "C" fn(*const CPrepareRequest, *mut CPackageMeta) -> i32,
    meta_free: unsafe extern "C" fn(*mut CPackageMeta),
}

impl Backend {
    pub fn load(kind: &BackendKind) -> Result<Self> {
        let so_lib = kind.so_name();
        let lib = unsafe { Library::new(so_lib) }
            .map_err(|err| anyhow::anyhow!("failed to load {so_lib}: {err}"))?;

        let prepare = unsafe {
            let symbol: Symbol<
                unsafe extern "C" fn(*const CPrepareRequest, *mut CPackageMeta) -> i32,
            > = lib
                .get(b"upac_backend_prepare")
                .map_err(|err| anyhow::anyhow!("symbol upac_backend_prepare not found: {err}"))?;
            *symbol
        };

        let meta_free = unsafe {
            let symbol: Symbol<unsafe extern "C" fn(*mut CPackageMeta)> = lib
                .get(b"upac_backend_meta_free")
                .map_err(|err| anyhow::anyhow!("symbol upac_backend_meta_free not found: {err}"))?;
            *symbol
        };

        Ok(Self {
            _lib: lib,
            prepare,
            meta_free,
        })
    }

    pub fn prepare(&self, pkg_path: &str, out_path: &str, checksum: &str) -> Result<PackageMeta> {
        let request = CPrepareRequest {
            pkg_path: CSlice::from_str(pkg_path),
            out_path: CSlice::from_str(out_path),
            checksum: CSlice::from_str(checksum),
        };

        let mut meta = std::mem::MaybeUninit::<CPackageMeta>::uninit();

        let code = unsafe { (self.prepare)(&request, meta.as_mut_ptr()) };

        if code != 0 {
            bail!("backend prepare failed with code {code}");
        }

        let c_meta = unsafe { meta.assume_init() };

        let result = unsafe {
            PackageMeta {
                name: c_meta.name.as_str().to_owned(),
                version: c_meta.version.as_str().to_owned(),
                author: c_meta.author.as_str().to_owned(),
                description: c_meta.description.as_str().to_owned(),
                license: c_meta.license.as_str().to_owned(),
                url: c_meta.url.as_str().to_owned(),
                installed_at: c_meta.installed_at,
                checksum: c_meta.checksum.as_str().to_owned(),
            }
        };

        let mut c_meta_owned = c_meta;
        unsafe { (self.meta_free)(&mut c_meta_owned) };

        Ok(result)
    }
}
