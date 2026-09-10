// SPDX-FileCopyrightText: 2026 JustPav
// SPDX-FileCopyrightText: 2026 SmoothTeam
//
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

use std::fs::File;
use std::str::from_utf8;

use upac_abi::DECODER_ABI_VERSION;
use upac_abi::decoder::{CDecodeRequest, CDecodeResponse, CDependency, DecodeError};
use upac_abi::memory::{free_cslice, free_cvec_owning};
use upac_abi::package::CPackageMeta;
use upac_abi::types::COwned;
use upac_abi::types::{CSlice, CVec};
use upac_types::decoder::{DecodeMeta, DecodedMeta};

pub mod header;
pub mod meta;
pub mod triggers;

mod extract;
mod verify;

include!(concat!(env!("OUT_DIR"), "/layout.rs"));

/// # Safety
/// Touches no pointers.
#[cfg_attr(feature = "cdylib", unsafe(no_mangle))]
pub unsafe extern "C" fn abi_version() -> u32 {
    DECODER_ABI_VERSION
}

/// # Safety
/// `request`, if non-null, must point to a valid, initialized `CDecodeRequest` for the duration
/// of the call. `response_out`, if non-null, must point to writable, uninitialized
/// `CDecodeResponse` storage that this function fully initializes on success.
#[cfg_attr(feature = "cdylib", unsafe(no_mangle))]
pub unsafe extern "C" fn decode(request: *const CDecodeRequest, response_out: *mut CDecodeResponse) -> i32 {
    if request.is_null() || response_out.is_null() {
        return DecodeError::InvalidRequest.code();
    }

    match decode_package(unsafe { &*request }) {
        Ok(response) => {
            unsafe { response_out.write(response) };
            0
        }
        Err(error) => error.code(),
    }
}

/// # Safety
/// `response`, if non-null, must point to a `CDecodeResponse` produced by this crate's own
/// `decode`, not yet freed.
unsafe extern "C" fn free_decode_response(response: *mut CDecodeResponse) {
    if response.is_null() {
        return;
    }

    let response = unsafe { &*response };

    unsafe {
        response.meta.free();

        free_cvec_owning(&response.dependencies, |dependency| {
            free_cslice(&dependency.name);
            dependency.version.free();
        });

        free_cvec_owning(&response.declarative_triggers, |slice| free_cslice(slice));
    }
}

fn decode_package(request: &CDecodeRequest) -> Result<CDecodeResponse, DecodeError> {
    let package_path =
        from_utf8(unsafe { request.package_path.as_slice() }).map_err(|_| DecodeError::InvalidRequest)?;
    let output_dir = from_utf8(unsafe { request.output_dir.as_slice() }).map_err(|_| DecodeError::InvalidRequest)?;
    let cancel = unsafe { request.cancel_token.as_ref() }.ok_or(DecodeError::InvalidRequest)?;

    verify::verify(package_path, request.checksum, cancel)?;

    let mut file = File::open(package_path)?;
    let header = header::read(&mut file)?;

    extract::extract(file, &header, output_dir, cancel)?;

    let declarative_triggers = triggers::scan(&header);
    let decoded = header.decode(request.checksum)?;

    Ok(build_response(decoded, declarative_triggers))
}

fn build_response(decoded: DecodedMeta, declarative_triggers: Vec<String>) -> CDecodeResponse {
    let DecodedMeta { meta, dependencies } = decoded;

    let dependencies = dependencies.into_iter().map(CDependency::from).collect::<Vec<_>>();

    let declarative_triggers = declarative_triggers
        .into_iter()
        .map(|trigger| CSlice::from_owned(trigger.into_bytes()))
        .collect::<Vec<_>>();

    CDecodeResponse {
        struct_size: size_of::<CDecodeResponse>(),

        meta: CPackageMeta::from(meta),

        dependencies: CVec::from_owned(dependencies),
        declarative_triggers: CVec::from_owned(declarative_triggers),

        free: free_decode_response,
    }
}
