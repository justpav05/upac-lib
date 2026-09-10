// SPDX-FileCopyrightText: 2026 JustPav
// SPDX-FileCopyrightText: 2026 SmoothTeam
//
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

use std::ffi::FromBytesWithNulError;
use std::str::Utf8Error;

#[repr(u32)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ErrorDomain {
    Uninstall,
    Install,
    Rollback,
    Commit,
    Files,
    Update,
    Gc,
    Pin,
    Mime,
    ListPackages,
    ListConfig,
    ListPrefix,
    ListHistory,
    DiffPrefix,
    DiffConfig,
    DiffPackages,
    Diff,
    SearchMeta,
    SearchFiles,
    SearchInMeta,
    SearchInPackageFiles,
}

#[repr(u32)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ErrorKind {
    Unexpected,
    OutOfMemory,
    NotFound,
    AlreadyExists,
    PermissionDenied,
    InvalidPath,
    NoSpaceLeft,
    Cancelled,
    ReadFailed,
    WriteFailed,
    NotInitialized,
    AbiMismatch,
    InvalidEntry,
}

impl From<FromBytesWithNulError> for ErrorKind {
    fn from(_: FromBytesWithNulError) -> Self {
        ErrorKind::InvalidEntry
    }
}

impl From<Utf8Error> for ErrorKind {
    fn from(_: Utf8Error) -> Self {
        ErrorKind::InvalidEntry
    }
}

#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct CError {
    pub domain: ErrorDomain,
    pub state: u32,
    pub error: ErrorKind,
}
