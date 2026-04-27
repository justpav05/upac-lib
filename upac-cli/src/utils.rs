// ── Imports ─────────────────────────────────────────────────────────────────
use anyhow::Result;

use indicatif::{ProgressBar, ProgressStyle};

use colored::Colorize;

use strum::{Display, EnumProperty, EnumString};

use std::fmt::Debug;
use std::time::Duration;

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

pub fn spinner(pb: &ProgressBar, msg: &str) {
    pb.set_style(
        ProgressStyle::default_spinner()
            .tick_strings(&["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"])
            .template("{spinner:.cyan} {msg}")
            .unwrap(),
    );
    pb.set_message(msg.to_owned());
    pb.enable_steady_tick(Duration::from_millis(80));
}
