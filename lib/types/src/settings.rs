// SPDX-FileCopyrightText: 2026 JustPav
// SPDX-FileCopyrightText: 2026 SmoothTeam
//
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

use std::fs::read_to_string;

use serde::Deserialize;

const RUNTIME_CONFIG_PATH: &str = "/etc/upac.d/upac.toml";

#[derive(Debug, Clone, Deserialize)]
#[serde(default)]
pub struct GcSettings {
    pub retention_depth: u64,
}

impl Default for GcSettings {
    fn default() -> Self {
        GcSettings { retention_depth: 5 }
    }
}

#[derive(Debug, Clone, Deserialize)]
#[serde(default)]
pub struct ProgressSettings {
    pub spinner_template: String,
    pub bar_template: String,
    pub tick_interval_ms: u64,
}

impl Default for ProgressSettings {
    fn default() -> Self {
        ProgressSettings {
            spinner_template: "{spinner:.cyan} {msg}".to_owned(),
            bar_template: "{spinner:.cyan} [{bar:32.cyan/blue}] {pos}/{len} {msg}".to_owned(),
            tick_interval_ms: 100,
        }
    }
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(default)]
pub struct BootSettings {
    pub plugin: Option<String>,
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(default)]
pub struct RuntimeSettings {
    pub gc: GcSettings,
    pub progress: ProgressSettings,
    pub boot: BootSettings,
}

impl RuntimeSettings {
    pub fn load() -> Self {
        read_to_string(RUNTIME_CONFIG_PATH)
            .ok()
            .and_then(|content| toml::from_str(&content).ok())
            .unwrap_or_default()
    }
}
