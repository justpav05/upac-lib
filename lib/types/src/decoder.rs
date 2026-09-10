// SPDX-FileCopyrightText: 2026 JustPav
// SPDX-FileCopyrightText: 2026 SmoothTeam
//
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

use std::fs::File;
use std::io::{BufReader, Read};

use sha2::{Digest, Sha256};

use upac_abi::FreeDecodeResponseFn;
use upac_abi::hook::CancelToken;
use upac_abi::package::{CPackageDependency, CPackageMeta};
use upac_abi::response::CDecodeResponse;
use upac_abi::types::{COwned, CSlice, CVec};

use upac_macro::RedbCodec;

use super::error::DecodeError;
use super::package::DecodedPackageMeta;

const VERIFY_CHUNK_SIZE: usize = 65536;

#[derive(Debug, Clone, RedbCodec)]
pub struct DeclarativeTrigger {
    pub format: String,
    pub triggers: Vec<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DecoderTrigger {
    PreInstall,
    PostInstall,
    PreUpgrade,
    PostUpgrade,
    PreRemove,
    PostRemove,
}

impl DecoderTrigger {
    pub const ALL: [DecoderTrigger; 6] = [
        DecoderTrigger::PreInstall,
        DecoderTrigger::PostInstall,
        DecoderTrigger::PreUpgrade,
        DecoderTrigger::PostUpgrade,
        DecoderTrigger::PreRemove,
        DecoderTrigger::PostRemove,
    ];
}

pub fn parse_constraint_prefix(token: &[u8], operators: &[(&[u8], u8)]) -> Option<(u8, usize)> {
    operators
        .iter()
        .find(|(operator, _)| token.starts_with(operator))
        .map(|(operator, constraint)| (*constraint, operator.len()))
}

pub fn read_to_string<R: Read>(reader: &mut R) -> Result<String, DecodeError> {
    let mut bytes = Vec::new();
    reader.read_to_end(&mut bytes)?;

    String::from_utf8(bytes).map_err(|_| DecodeError::InvalidUtf8)
}

pub fn verify(package_path: &str, expected_checksum: [u8; 32], cancel: &CancelToken) -> Result<(), DecodeError> {
    let file = File::open(package_path)?;
    let mut reader = BufReader::new(file);

    let mut hasher = Sha256::new();
    let mut buffer = [0u8; VERIFY_CHUNK_SIZE];

    loop {
        if cancel.is_cancelled() {
            return Err(DecodeError::Cancelled);
        }

        let bytes_read = reader.read(&mut buffer)?;
        if bytes_read == 0 {
            break;
        }

        hasher.update(&buffer[..bytes_read]);
    }

    if hasher.finalize().as_slice() != expected_checksum.as_slice() {
        return Err(DecodeError::ChecksumMismatch);
    }

    Ok(())
}

pub fn build_decode_response(
    decoded: DecodedPackageMeta, declarative_triggers: Vec<String>, free: FreeDecodeResponseFn,
) -> CDecodeResponse {
    let DecodedPackageMeta { meta, dependencies } = decoded;

    let dependencies = dependencies
        .into_iter()
        .map(CPackageDependency::from)
        .collect::<Vec<_>>();

    let declarative_triggers = declarative_triggers
        .into_iter()
        .map(|trigger| CSlice::from_owned(trigger.into_bytes()))
        .collect::<Vec<_>>();

    CDecodeResponse::new(
        CPackageMeta::from(meta),
        CVec::from_owned(dependencies),
        CVec::from_owned(declarative_triggers),
        free,
    )
}
