// ── Imports ─────────────────────────────────────────────────────────────────
use anyhow::Result;
use strum::{Display, EnumProperty, EnumString};

// ── Backend Definition ────────────────────────────────────────
// Represents the type of backend (ALPM, RPM, DEB) for a package
#[derive(Debug, Clone, Hash, Eq, PartialEq, Display, EnumString, EnumProperty)]
pub enum BackendKind {
    #[strum(serialize = "arch", to_string = "alpm", props(so = "libupac-alpm.so"))]
    Alpm,
    #[strum(serialize = "rpm", props(so = "libupac-rpm.so"))]
    Rpm,
    #[strum(serialize = "deb", props(so = "libupac-deb.so"))]
    Deb,
    #[strum(serialize = "upaclib", props(so = "libupac.so"))]
    UpacLib,
}

impl BackendKind {
    pub fn detect(file_path: &str) -> Option<Self> {
        let known_extensions = [
            (".pkg.tar.zst", Self::Alpm),
            (".pkg.tar.xz", Self::Alpm),
            (".pkg.tar.gz", Self::Alpm),
            (".rpm", Self::Rpm),
            (".deb", Self::Deb),
        ];

        known_extensions
            .iter()
            .find(|(extension, _)| file_path.ends_with(extension))
            .map(|(_, backend_kind)| backend_kind.clone())
    }

    pub fn from_flag(flag_string: &str) -> Result<Self> {
        flag_string.parse().map_err(|_| {
            anyhow::anyhow!("unknown backend: '{flag_string}'. Available: arch, rpm, deb")
        })
    }

    pub fn so_name(&self) -> &'static str {
        self.get_str("so").expect("so property not defined")
    }
}
