// SPDX-FileCopyrightText: 2026 JustPav
// SPDX-FileCopyrightText: 2026 SmoothTeam
//
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

use std::collections::HashMap;
use std::fs;
use std::io::ErrorKind;
use std::str::FromStr;

use mime::Mime;

use serde::Deserialize;

use crate::layout::decoders::{DECODERS_DIR, MANIFEST_EXTENSION};
use crate::plugin::decoder::error::DecoderError;

#[derive(Debug, Clone, Deserialize)]
pub struct DecoderManifest {
    pub format: String,
    pub extensions: Vec<String>,
    pub library: String,
    pub mime: String,
}

pub struct DecoderManifests(pub HashMap<String, DecoderManifest>);

impl DecoderManifests {
    pub fn new() -> Result<Self, DecoderError> {
        let mut manifests = HashMap::new();

        let dir = match fs::read_dir(DECODERS_DIR) {
            Ok(dir) => dir,
            Err(error) if error.kind() == ErrorKind::NotFound => return Ok(DecoderManifests(manifests)),
            Err(error) => return Err(error.into()),
        };

        for entry in dir {
            let path = entry?.path();

            if path.extension().and_then(|extension| extension.to_str()) != Some(MANIFEST_EXTENSION) {
                continue;
            }

            let raw = fs::read_to_string(&path)?;
            let manifest: DecoderManifest = toml::from_str(&raw)?;

            Mime::from_str(&manifest.mime)?;

            if manifests.contains_key(&manifest.format) {
                return Err(DecoderError::DuplicateFormat(manifest.format));
            }

            manifests.insert(manifest.format.clone(), manifest);
        }

        Ok(DecoderManifests(manifests))
    }
}
