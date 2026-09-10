// SPDX-FileCopyrightText: 2026 JustPav
// SPDX-FileCopyrightText: 2026 SmoothTeam
//
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

use upac_abi::hook::CancelToken;

use upac_types::decoder::DeclarativeTrigger;
use upac_types::package::PackageTemp;

use crate::plugin::decoder::error::DecoderError;

#[cfg(any(feature = "dynamic-plugins", feature = "builtin-decoders"))]
use std::fs::{File, create_dir_all, remove_dir_all};
#[cfg(any(feature = "dynamic-plugins", feature = "builtin-decoders"))]
use std::io::Read;
#[cfg(any(feature = "dynamic-plugins", feature = "builtin-decoders"))]
use std::path::Path;

#[cfg(any(feature = "dynamic-plugins", feature = "builtin-decoders"))]
use sha2::{Digest, Sha256};

#[cfg(any(feature = "dynamic-plugins", feature = "builtin-decoders"))]
use crate::plugin::decoder::DecoderPlugin;

#[cfg(feature = "dynamic-plugins")]
use std::collections::HashMap;

#[cfg(feature = "dynamic-plugins")]
use crate::plugin::decoder::dynamic_link::load_decoder_dynamic;
#[cfg(feature = "dynamic-plugins")]
use crate::plugin::decoder::manifest::DecoderManifests;

#[cfg(feature = "builtin-decoders")]
use crate::plugin::decoder::static_link::static_decoders;

#[cfg(any(feature = "dynamic-plugins", feature = "builtin-decoders"))]
fn checksum_of_file(path: &str) -> Result<[u8; 32], DecoderError> {
    let mut file = File::open(path)?;
    let mut hasher = Sha256::new();
    let mut buffer = [0u8; 65536];

    loop {
        let bytes_read = file.read(&mut buffer)?;
        if bytes_read == 0 {
            break;
        }
        hasher.update(&buffer[..bytes_read]);
    }

    Ok(hasher.finalize().into())
}

pub struct PackageUnpacker {
    #[cfg(feature = "dynamic-plugins")]
    manifests: DecoderManifests,

    #[cfg(feature = "dynamic-plugins")]
    decoders: HashMap<String, DecoderPlugin>,

    #[cfg(feature = "builtin-decoders")]
    static_decoders: Vec<(&'static str, &'static [&'static str], DecoderPlugin)>,
}

#[cfg(any(feature = "dynamic-plugins", feature = "builtin-decoders"))]
impl PackageUnpacker {
    pub fn unpack_one(
        &mut self, package_path: &str, index: usize, tmp_path: &str, cancel: &CancelToken,
    ) -> Result<(PackageTemp, DeclarativeTrigger), DecoderError> {
        let format = self.format_for(package_path)?;
        let checksum = checksum_of_file(package_path)?;

        let output_dir = format!("{tmp_path}/pkg-{index}");
        create_dir_all(&output_dir)?;

        let decoder = self.decoder_for(&format).inspect_err(|_| {
            let _ = remove_dir_all(&output_dir);
        })?;

        let decoded = decoder
            .decode(package_path, &output_dir, checksum, cancel)
            .inspect_err(|_| {
                let _ = remove_dir_all(&output_dir);
            })?;

        Ok((
            PackageTemp {
                meta: decoded.meta,
                temp_package_path: output_dir,
            },
            DeclarativeTrigger {
                format,
                triggers: decoded.declarative_triggers,
            },
        ))
    }
}

#[cfg(feature = "dynamic-plugins")]
impl PackageUnpacker {
    pub fn new() -> Result<Self, DecoderError> {
        Ok(Self {
            manifests: DecoderManifests::new()?,
            decoders: HashMap::new(),

            #[cfg(feature = "builtin-decoders")]
            static_decoders: Vec::new(),
        })
    }

    fn format_for(&self, package_path: &str) -> Result<String, DecoderError> {
        let extension = Path::new(package_path)
            .extension()
            .and_then(|extension| extension.to_str())
            .ok_or_else(|| DecoderError::UnknownFormat(package_path.to_owned()))?;

        self.manifests
            .0
            .values()
            .find(|manifest| manifest.extensions.iter().any(|candidate| candidate == extension))
            .map(|manifest| manifest.format.clone())
            .ok_or_else(|| DecoderError::UnknownFormat(package_path.to_owned()))
    }

    fn decoder_for(&mut self, format: &str) -> Result<&DecoderPlugin, DecoderError> {
        if !self.decoders.contains_key(format) {
            let decoder = load_decoder_dynamic(&self.manifests, format)?;
            self.decoders.insert(format.to_owned(), decoder);
        }

        Ok(&self.decoders[format])
    }
}

#[cfg(all(not(feature = "dynamic-plugins"), feature = "builtin-decoders"))]
impl PackageUnpacker {
    pub fn new() -> Result<Self, DecoderError> {
        Ok(Self {
            #[cfg(feature = "dynamic-plugins")]
            manifests: DecoderManifests::new()?,

            #[cfg(feature = "dynamic-plugins")]
            decoders: HashMap::new(),

            static_decoders: static_decoders(),
        })
    }

    fn format_for(&self, package_path: &str) -> Result<String, DecoderError> {
        let extension = Path::new(package_path)
            .extension()
            .and_then(|extension| extension.to_str())
            .ok_or_else(|| DecoderError::UnknownFormat(package_path.to_owned()))?;

        self.static_decoders
            .iter()
            .find(|(_, extensions, _)| extensions.contains(&extension))
            .map(|(format, _, _)| (*format).to_owned())
            .ok_or_else(|| DecoderError::UnknownFormat(package_path.to_owned()))
    }

    fn decoder_for(&mut self, format: &str) -> Result<&DecoderPlugin, DecoderError> {
        self.static_decoders
            .iter()
            .find(|(name, _, _)| *name == format)
            .map(|(_, _, decoder)| decoder)
            .ok_or_else(|| DecoderError::UnknownFormat(format.to_owned()))
    }
}

#[cfg(all(not(feature = "dynamic-plugins"), not(feature = "builtin-decoders")))]
impl PackageUnpacker {
    /// Always fails: this build contains no decoder loading path.
    pub fn new() -> Result<Self, DecoderError> {
        Err(DecoderError::NoDecoders)
    }

    pub fn unpack_one(
        &mut self, _package_path: &str, _index: usize, _tmp_path: &str, _cancel: &CancelToken,
    ) -> Result<(PackageTemp, DeclarativeTrigger), DecoderError> {
        Err(DecoderError::NoDecoders)
    }
}
