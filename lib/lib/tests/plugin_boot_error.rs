// SPDX-FileCopyrightText: 2026 JustPav
// SPDX-FileCopyrightText: 2026 SmoothTeam
//
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

use std::io::{Error as IoError, ErrorKind as IoErrorKind};

use upac::plugin::boot::error::BootPluginError;

use upac_abi::error::ErrorKind;

#[test]
fn io_error_maps_to_io_with_the_same_kind() {
    let error = IoError::new(IoErrorKind::PermissionDenied, "denied");

    assert_eq!(
        BootPluginError::from(error),
        BootPluginError::Io(IoErrorKind::PermissionDenied)
    );
}

#[test]
fn toml_error_maps_to_manifest() {
    let error = toml::from_str::<toml::Value>("not valid toml [[[").unwrap_err();

    assert_eq!(BootPluginError::from(error), BootPluginError::Manifest);
}

#[test]
fn every_variant_maps_to_the_documented_error_kind() {
    let cases = [
        (BootPluginError::Load, ErrorKind::NotFound),
        (BootPluginError::Symbol, ErrorKind::AbiMismatch),
        (
            BootPluginError::AbiMismatch { got: 1, expected: 2 },
            ErrorKind::AbiMismatch,
        ),
        (
            BootPluginError::Reported(ErrorKind::PermissionDenied),
            ErrorKind::PermissionDenied,
        ),
        (BootPluginError::Io(IoErrorKind::NotFound), ErrorKind::ReadFailed),
        (BootPluginError::Manifest, ErrorKind::InvalidEntry),
        (
            BootPluginError::DuplicateName("uki".to_owned()),
            ErrorKind::InvalidEntry,
        ),
        (BootPluginError::UnknownName("uki".to_owned()), ErrorKind::NotFound),
        (BootPluginError::NoClaimant, ErrorKind::NotFound),
        (BootPluginError::AmbiguousClaim, ErrorKind::InvalidEntry),
    ];

    for (error, expected) in cases {
        assert_eq!(ErrorKind::from(error), expected);
    }
}
