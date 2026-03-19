use anyhow::{Context, Result};

use serde::Deserialize;

use std::fs;

const CONFIG_PATH: &str = "/etc/upac/config.toml";

#[derive(Debug, Deserialize)]
pub struct Config {
    pub paths: Paths,
    pub ostree: OstreeConfig,
}

#[derive(Debug, Deserialize)]
pub struct Paths {
    pub db_path: String,
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
    pub fn load() -> Result<Self> {
        let content = fs::read_to_string(CONFIG_PATH)
            .with_context(|| format!("failed to read config file: {CONFIG_PATH}"))?;

        let config: Config = toml::from_str(&content)
            .with_context(|| format!("failed to parse config file: {CONFIG_PATH}"))?;

        config.validate()?;

        Ok(config)
    }

    fn validate(&self) -> Result<()> {
        if self.paths.db_path.is_empty() {
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
