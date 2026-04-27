// ── Imports ─────────────────────────────────────────────────────────────────
use anyhow::{Context, Result};

use smart_default::SmartDefault;

use serde::Deserialize;

use std::ffi::CString;
use std::fs;
use std::path::Path;

// ── Main config ─────────────────────────────────────────────────────────────────
// The main application configuration structure, combining settings for logging, paths, and OSTree.
#[derive(Debug, Deserialize, Clone, SmartDefault)]
pub struct Config {
    #[serde(default)]
    pub verbose: bool,
    #[default = 3]
    pub step_retries: u8,
    #[serde(alias = "paths")]
    pub paths: Paths,
    pub ostree: OstreeConfig,
}

// Set of paths to key system components: database, repository, and OS root
#[derive(Debug, Deserialize, Clone, SmartDefault)]
pub struct Paths {
    #[serde(alias = "db_path")]
    #[default(CString::new("/usr/share/upac/db").unwrap())]
    pub database_path: CString,
    #[default(CString::new("/var/share/upac/repo").unwrap())]
    pub repo_path: CString,
    #[default(CString::new("/").unwrap())]
    pub root_path: CString,
}

// OSTree-specific settings, such as the branch name for commits
#[derive(Debug, Deserialize, Clone, SmartDefault)]
pub struct OstreeConfig {
    #[default(CString::new("archive").unwrap())]
    pub mode: CString,
    #[default(CString::new("packages").unwrap())]
    pub branch: CString,
    #[default(CString::new("usr").unwrap())]
    pub prefix_directory: CString,
}

// ── Validation ─────────────────────────────────────────────────────────────────
impl Config {
    // Loads the configuration from a TOML file and validates it
    pub fn load(config_path: &Path) -> Result<Self> {
        let config_file_content = fs::read_to_string(config_path)
            .with_context(|| format!("failed to read config file: {config_path:?}"))?;

        let config: Config = toml::from_str(&config_file_content).map_err(|err| {
            anyhow::anyhow!(
                "failed to parse config file {}: {err}",
                config_path.display()
            )
        })?;

        config.validate()?;

        Ok(config)
    }

    // Validates the configuration, ensuring all paths and values are set correctly
    fn validate(&self) -> Result<()> {
        if self.paths.repo_path.is_empty() {
            anyhow::bail!("config: paths.db_path is empty");
        }
        if self.paths.repo_path.is_empty() {
            anyhow::bail!("config: paths.repo_path is empty");
        }
        if self.paths.root_path.is_empty() {
            anyhow::bail!("config: paths.root_path is empty");
        }
        if self.ostree.branch.is_empty() {
            anyhow::bail!("config: ostree.branch is empty");
        }
        if self.ostree.mode.is_empty() {
            anyhow::bail!("config: ostree.mode is empty");
        }

        Ok(())
    }
}
