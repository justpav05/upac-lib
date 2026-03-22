use anyhow::{Context, Result};

use serde::Deserialize;

use std::fs;
use std::path::Path;

#[derive(Debug, Deserialize)]
pub struct Config {
    #[serde(default)]
    pub verbose: bool,
    #[serde(alias = "paths")]
    pub paths: Paths,
    pub ostree: OstreeConfig,
}

#[derive(Debug, Deserialize)]
pub struct Paths {
    #[serde(alias = "db_path")]
    pub database_path: String,
    #[serde(default = "default_config_path")]
    pub config_path: String,
    pub repo_path: String,
    pub root_path: String,
    pub ostree_path: String,
}

#[derive(Debug, Deserialize)]
pub struct OstreeConfig {
    pub enabled: bool,
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
        if self.paths.database_path.is_empty() {
            anyhow::bail!("config: paths.db_path is empty");
        }
        if self.paths.repo_path.is_empty() {
            anyhow::bail!("config: paths.repo_path is empty");
        }
        if self.paths.root_path.is_empty() {
            anyhow::bail!("config: paths.root_path is empty");
        }
        if self.paths.ostree_path.is_empty() {
            anyhow::bail!("config: paths.ostree_path is empty");
        }
        if self.ostree.enabled && self.ostree.branch.is_empty() {
            anyhow::bail!("config: ostree.branch is empty but ostree is enabled");
        }

        Ok(())
    }
}

fn default_config_path() -> String {
    "/etc/upac/config.toml".to_owned()
}
