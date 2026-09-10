// SPDX-FileCopyrightText: 2026 JustPav
// SPDX-FileCopyrightText: 2026 SmoothTeam
//
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

use std::collections::HashMap;
use std::fs::{read_dir, read_to_string};
use std::io::ErrorKind;

use serde::Deserialize;

use super::error::BootPluginError;

use crate::layout::boot_plugins::{BOOT_PLUGINS_DIR, MANIFEST_EXTENSION};

#[derive(Debug, Clone, Deserialize)]
pub struct BootPluginManifest {
    pub name: String,
    pub library: String,
}

pub struct BootPluginManifests(pub HashMap<String, BootPluginManifest>);

impl BootPluginManifests {
    pub fn new() -> Result<Self, BootPluginError> {
        let mut manifests = HashMap::new();

        let dir = match read_dir(BOOT_PLUGINS_DIR) {
            Ok(dir) => dir,
            Err(error) if error.kind() == ErrorKind::NotFound => return Ok(BootPluginManifests(manifests)),
            Err(error) => return Err(error.into()),
        };

        for entry in dir {
            let path = entry?.path();

            if path.extension().and_then(|extension| extension.to_str()) != Some(MANIFEST_EXTENSION) {
                continue;
            }

            let raw = read_to_string(&path)?;
            let manifest: BootPluginManifest = toml::from_str(&raw)?;

            if manifests.contains_key(&manifest.name) {
                return Err(BootPluginError::DuplicateName(manifest.name));
            }

            manifests.insert(manifest.name.clone(), manifest);
        }

        Ok(BootPluginManifests(manifests))
    }
}
