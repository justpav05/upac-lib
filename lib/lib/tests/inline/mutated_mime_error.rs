// SPDX-FileCopyrightText: 2026 JustPav
// SPDX-FileCopyrightText: 2026 SmoothTeam
//
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

use upac_abi::error::ErrorKind;

use super::{CommonError, IoError, IoErrorKind, MimeError};

#[test]
fn io_error_maps_to_io_with_the_same_kind() {
    let error = IoError::new(IoErrorKind::PermissionDenied, "denied");

    assert_eq!(MimeError::from(error), MimeError::Io(IoErrorKind::PermissionDenied));
}

#[test]
fn every_own_variant_maps_to_the_documented_error_kind() {
    let cases = [
        (MimeError::Common(CommonError::OutOfMemory), ErrorKind::OutOfMemory),
        (MimeError::Io(IoErrorKind::NotFound), ErrorKind::NotFound),
        (
            MimeError::Io(IoErrorKind::PermissionDenied),
            ErrorKind::PermissionDenied,
        ),
        (MimeError::Io(IoErrorKind::Other), ErrorKind::Unexpected),
        (MimeError::DesktopFileMalformed, ErrorKind::InvalidEntry),
    ];

    for (error, expected) in cases {
        assert_eq!(ErrorKind::from(error), expected);
    }
}
