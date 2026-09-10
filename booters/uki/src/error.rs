// SPDX-FileCopyrightText: 2026 JustPav
// SPDX-FileCopyrightText: 2026 SmoothTeam
//
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

use std::any::Any;
use std::io::{Error as IoError, ErrorKind as IoErrorKind};

use efivar::Error as EfivarError;

use upac_abi::error::ErrorKind;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum UkiError {
    EfiUnavailable,
    PermissionDenied,
    EntryNotFound,
    NoFreeBootId,
    InvalidRequest,
    Unexpected,
}

impl From<EfivarError> for UkiError {
    fn from(error: EfivarError) -> Self {
        match error {
            EfivarError::PermissionDenied { .. } => UkiError::PermissionDenied,
            _ => UkiError::Unexpected,
        }
    }
}

impl From<IoError> for UkiError {
    fn from(error: IoError) -> Self {
        match error.kind() {
            IoErrorKind::NotFound => UkiError::EntryNotFound,
            IoErrorKind::PermissionDenied => UkiError::PermissionDenied,
            _ => UkiError::Unexpected,
        }
    }
}

impl From<Box<dyn Any + Send + 'static>> for UkiError {
    fn from(_: Box<dyn Any + Send + 'static>) -> Self {
        UkiError::EfiUnavailable
    }
}

impl From<UkiError> for ErrorKind {
    fn from(error: UkiError) -> Self {
        match error {
            UkiError::EfiUnavailable => ErrorKind::NotInitialized,
            UkiError::PermissionDenied => ErrorKind::PermissionDenied,
            UkiError::EntryNotFound => ErrorKind::NotFound,
            UkiError::NoFreeBootId => ErrorKind::OutOfMemory,
            UkiError::InvalidRequest => ErrorKind::InvalidEntry,
            UkiError::Unexpected => ErrorKind::Unexpected,
        }
    }
}
