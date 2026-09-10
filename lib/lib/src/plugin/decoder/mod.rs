// SPDX-FileCopyrightText: 2026 JustPav
// SPDX-FileCopyrightText: 2026 SmoothTeam
//
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

use std::mem::MaybeUninit;

use upac_abi::DecodeFn;
use upac_abi::hook::CancelToken;
use upac_abi::request::CDecodeRequest;
use upac_abi::response::CDecodeResponse;

use upac_types::request::DecodeRequest;
use upac_types::response::DecodeResponse;

#[cfg(feature = "dynamic-plugins")]
use libloading::Library;

use crate::plugin::decoder::error::DecoderError;

#[cfg(all(feature = "dynamic-plugins", feature = "builtin-decoders"))]
compile_error!("dynamic-plugins and builtin-decoders are mutually exclusive");

#[cfg(feature = "dynamic-plugins")]
pub mod dynamic_link;
pub mod error;
pub mod manifest;
#[cfg(feature = "builtin-decoders")]
pub mod static_link;
pub mod triggers;
pub mod unpack;

pub struct DecoderPlugin {
    decode: DecodeFn,

    #[cfg(feature = "dynamic-plugins")]
    _library: Option<Library>,
}

impl DecoderPlugin {
    pub fn decode(
        &self, package_path: &str, output_dir: &str, checksum: [u8; 32], cancel: &CancelToken,
    ) -> Result<DecodeResponse, DecoderError> {
        let request: CDecodeRequest = DecodeRequest {
            package_path: package_path.to_owned(),
            output_dir: output_dir.to_owned(),
            checksum,
            cancel_token: cancel as *const CancelToken as *mut CancelToken,
        }
        .into();

        let mut response = MaybeUninit::<CDecodeResponse>::uninit();

        let code = unsafe { (self.decode)(&request, response.as_mut_ptr()) };
        if code != 0 {
            return Err(DecoderError::Failed(code));
        }

        let response = unsafe { response.assume_init() };

        Ok(DecodeResponse::try_from(&response)?)
    }
}
