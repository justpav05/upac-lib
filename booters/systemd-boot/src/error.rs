// SPDX-FileCopyrightText: 2026 JustPav
// SPDX-FileCopyrightText: 2026 SmoothTeam
//
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

use std::any::Any;

use efivar::Error as EfivarError;

use uuid::Error as UuidError;

use upac_abi::error::ErrorKind;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SystemdBootError {
    EfiUnavailable,
    PermissionDenied,
    InvalidRequest,
    Unexpected,
}

impl From<EfivarError> for SystemdBootError {
    fn from(error: EfivarError) -> Self {
        match error {
            EfivarError::PermissionDenied { .. } => SystemdBootError::PermissionDenied,
            _ => SystemdBootError::Unexpected,
        }
    }
}

impl From<UuidError> for SystemdBootError {
    fn from(_: UuidError) -> Self {
        SystemdBootError::Unexpected
    }
}

impl From<Box<dyn Any + Send + 'static>> for SystemdBootError {
    fn from(_: Box<dyn Any + Send + 'static>) -> Self {
        SystemdBootError::EfiUnavailable
    }
}

impl From<SystemdBootError> for ErrorKind {
    fn from(error: SystemdBootError) -> Self {
        match error {
            SystemdBootError::EfiUnavailable => ErrorKind::NotInitialized,
            SystemdBootError::PermissionDenied => ErrorKind::PermissionDenied,
            SystemdBootError::InvalidRequest => ErrorKind::InvalidEntry,
            SystemdBootError::Unexpected => ErrorKind::Unexpected,
        }
    }
}
