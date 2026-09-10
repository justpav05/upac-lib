// SPDX-FileCopyrightText: 2026 JustPav
// SPDX-FileCopyrightText: 2026 SmoothTeam
//
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

use std::io::{Error as IoError, ErrorKind as IoErrorKind};
use std::str::from_utf8;

use upac::scripts::error::HookError;

use upac_abi::error::ErrorKind;

use upac_pki::error::PkiError;

#[test]
fn toml_error_maps_to_parse() {
    let error = toml::from_str::<toml::Value>("not valid toml [[[").unwrap_err();

    assert_eq!(HookError::from(error), HookError::Parse);
}

#[test]
fn io_error_maps_to_io_with_the_same_kind() {
    let error = IoError::new(IoErrorKind::PermissionDenied, "denied");

    assert_eq!(HookError::from(error), HookError::Io(IoErrorKind::PermissionDenied));
}

#[test]
fn utf8_error_maps_to_encoding() {
    let bytes: Vec<u8> = vec![0xff, 0xfe];
    let error = from_utf8(&bytes).unwrap_err();

    assert_eq!(HookError::from(error), HookError::Encoding);
}

#[test]
fn pki_error_maps_each_variant_directly() {
    let cases = [
        (PkiError::Malformed, HookError::MalformedSignature),
        (PkiError::InvalidSignature, HookError::InvalidSignature),
        (PkiError::Generation, HookError::Parse),
    ];

    for (error, expected) in cases {
        assert_eq!(HookError::from(error), expected);
    }
}

#[test]
fn every_variant_maps_to_the_documented_error_kind() {
    let cases = [
        (HookError::Parse, ErrorKind::InvalidEntry),
        (HookError::InvalidTrigger, ErrorKind::InvalidEntry),
        (HookError::NoTrigger, ErrorKind::InvalidEntry),
        (HookError::Io(IoErrorKind::NotFound), ErrorKind::ReadFailed),
        (HookError::Encoding, ErrorKind::InvalidEntry),
        (HookError::MalformedSignature, ErrorKind::InvalidEntry),
        (HookError::InvalidSignature, ErrorKind::InvalidEntry),
        (HookError::TriggerConflict("deb".to_owned()), ErrorKind::InvalidEntry),
    ];

    for (error, expected) in cases {
        assert_eq!(ErrorKind::from(error), expected);
    }
}
