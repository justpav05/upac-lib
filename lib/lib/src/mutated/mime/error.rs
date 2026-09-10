// SPDX-FileCopyrightText: 2026 JustPav
// SPDX-FileCopyrightText: 2026 SmoothTeam
//
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

use std::io::Error as IoError;
use std::io::ErrorKind as IoErrorKind;

use upac_abi::error::ErrorKind;

use crate::errors::{CommonError, common_error_from, lock_error_from};
use crate::lock::LockError;

#[cfg(test)]
#[path = "../../../tests/inline/mutated_mime_error.rs"]
mod tests;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum MimeError {
    Common(CommonError),
    Io(IoErrorKind),
    DesktopFileMalformed,
}

common_error_from!(MimeError);

lock_error_from!(MimeError);

impl From<IoError> for MimeError {
    fn from(error: IoError) -> Self {
        MimeError::Io(error.kind())
    }
}

impl From<MimeError> for ErrorKind {
    fn from(error: MimeError) -> Self {
        match error {
            MimeError::Common(common_error) => common_error.into(),
            MimeError::Io(kind) => match kind {
                IoErrorKind::NotFound => ErrorKind::NotFound,
                IoErrorKind::PermissionDenied => ErrorKind::PermissionDenied,
                _ => ErrorKind::Unexpected,
            },
            MimeError::DesktopFileMalformed => ErrorKind::InvalidEntry,
        }
    }
}
