// ── Imports ─────────────────────────────────────────────────────────────────
use anyhow::{Context, Result};

use serde::Deserialize;

use std::ffi::CString;
use std::fs;
use std::path::Path;

// ── Main config ─────────────────────────────────────────────────────────────────
// The main application configuration structure, combining settings for logging, paths, and OSTree.
#[derive(Debug, Deserialize, Clone)]
pub struct Config {
    #[serde(default)]
    pub verbose: bool,
    pub step_retries: u8,
    #[serde(alias = "paths")]
    pub paths: Paths,
    pub ostree: OstreeConfig,
}

impl Default for Config {
    fn default() -> Self {
        Self {
            verbose: false,
            step_retries: 3,
            paths: Paths::default(),
            ostree: OstreeConfig::default(),
        }
    }
}

// Set of paths to key system components: database, repository, and OS root
#[derive(Debug, Deserialize, Clone)]
pub struct Paths {
    #[serde(alias = "db_path")]
    pub database_path: CString,
    pub repo_path: CString,
    pub root_path: CString,
}

impl Default for Paths {
    fn default() -> Self {
        Self {
            database_path: CString::new("/usr/share/upac/db").unwrap(),
            repo_path: CString::new("/var/share/upac/repo").unwrap(),
            root_path: CString::new("/").unwrap(),
        }
    }
}

// OSTree-specific settings, such as the branch name for commits
#[derive(Debug, Deserialize, Clone)]
pub struct OstreeConfig {
    pub mode: CString,
    pub branch: CString,

    pub prefix_directory: CString,
}

impl Default for OstreeConfig {
    fn default() -> Self {
        Self {
            mode: CString::new("archive").unwrap(),
            branch: CString::new("packages").unwrap(),
            prefix_directory: CString::new("usr").unwrap(),
        }
    }
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
