// SPDX-FileCopyrightText: 2026 JustPav
// SPDX-FileCopyrightText: 2026 SmoothTeam
//
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

use std::array::TryFromSliceError;

use der::Error as DerError;

use rcgen::Error as RcgenError;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PkiError {
    Malformed,
    InvalidSignature,
    Generation,
}

impl From<DerError> for PkiError {
    fn from(_: DerError) -> Self {
        PkiError::Malformed
    }
}

impl From<RcgenError> for PkiError {
    fn from(_: RcgenError) -> Self {
        PkiError::Generation
    }
}

impl From<TryFromSliceError> for PkiError {
    fn from(_: TryFromSliceError) -> Self {
        PkiError::Malformed
    }
}
