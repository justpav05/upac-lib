// SPDX-FileCopyrightText: 2026 JustPav
// SPDX-FileCopyrightText: 2026 SmoothTeam
//
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

use std::io::Error as IoError;
use std::io::ErrorKind as IoErrorKind;

use upac_abi::error::ErrorDomain;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DecodeError {
    InvalidRequest,
    Io(IoErrorKind),
    ChecksumMismatch,
    UnsupportedFormat,
    MissingMetadata,
    MalformedMetadata,
    InvalidUtf8,
    Cancelled,
}

impl From<IoError> for DecodeError {
    fn from(error: IoError) -> Self {
        DecodeError::Io(error.kind())
    }
}

impl DecodeError {
    pub fn code(self) -> i32 {
        match self {
            DecodeError::InvalidRequest => -1,
            DecodeError::Io(_) => -2,
            DecodeError::ChecksumMismatch => -3,
            DecodeError::UnsupportedFormat => -4,
            DecodeError::MissingMetadata => -5,
            DecodeError::MalformedMetadata => -6,
            DecodeError::InvalidUtf8 => -7,
            DecodeError::Cancelled => -8,
        }
    }
}

pub trait CommandState: Copy {
    const DOMAIN: ErrorDomain;
    const VALIDATION: Self;

    fn as_u32(self) -> u32;
}
