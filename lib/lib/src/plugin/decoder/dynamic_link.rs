// SPDX-FileCopyrightText: 2026 JustPav
// SPDX-FileCopyrightText: 2026 SmoothTeam
//
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

use libloading::Library;

use upac_abi::{DECODER_ABI_VERSION, DecodeFn, DecodePluginAbiVersionFn};

use super::DecoderPlugin;
use super::error::DecoderError;
use super::manifest::DecoderManifests;

macro_rules! load_symbol {
    ($library:expr, $name:literal) => {
        unsafe { load_symbol(&$library, $name)? }
    };
}

unsafe fn load_symbol<T: Copy>(library: &Library, name: &str) -> Result<T, DecoderError> {
    unsafe { library.get::<T>(name.as_bytes()) }
        .map(|symbol| *symbol)
        .map_err(|_| DecoderError::Symbol)
}

impl DecoderPlugin {
    pub(super) fn load_plugin(library_name: &str) -> Result<Self, DecoderError> {
        let library = unsafe { Library::new(library_name) }.map_err(|_| DecoderError::Load)?;

        let abi_version: DecodePluginAbiVersionFn = load_symbol!(library, "decode_abi_version");
        let decode: DecodeFn = load_symbol!(library, "decode");

        let got_abi_version = unsafe { abi_version() };
        if got_abi_version != DECODER_ABI_VERSION {
            return Err(DecoderError::AbiMismatch {
                got: got_abi_version,
                expected: DECODER_ABI_VERSION,
            });
        }

        Ok(DecoderPlugin {
            decode,
            _library: Some(library),
        })
    }
}

pub(super) fn load_decoder_dynamic(manifests: &DecoderManifests, format: &str) -> Result<DecoderPlugin, DecoderError> {
    let manifest = manifests
        .0
        .get(format)
        .ok_or_else(|| DecoderError::UnknownFormat(format.to_owned()))?;

    DecoderPlugin::load_plugin(&manifest.library)
}
