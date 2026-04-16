use anyhow::{Context, Result};

use smart_default::SmartDefault;

use serde::Deserialize;

use std::fs;
use std::path::Path;

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

#[derive(Debug, Deserialize, Clone, SmartDefault)]
pub struct Paths {
    #[serde(alias = "db_path")]
    #[default = "/usr/share/upac/db"]
    pub database_path: String,
    #[default = "/var/share/upac/repo"]
    pub repo_path: String,
    #[default = "/"]
    pub root_path: String,
}

#[derive(Debug, Deserialize, Clone, SmartDefault)]
pub struct OstreeConfig {
    #[default = "packages"]
    pub branch: String,
}

impl Config {
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

        Ok(())
    }
}
