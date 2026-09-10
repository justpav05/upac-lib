// SPDX-FileCopyrightText: 2026 JustPav
// SPDX-FileCopyrightText: 2026 SmoothTeam
//
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

use std::io::{Error as IoError, ErrorKind as IoErrorKind};

use mime::Mime;

use upac::plugin::decoder::error::DecoderError;

use upac_abi::error::ErrorKind;

#[test]
fn abi_error_kind_maps_to_invalid_response() {
    let error = ErrorKind::AbiMismatch;

    assert_eq!(DecoderError::from(error), DecoderError::InvalidResponse);
}

#[test]
fn io_error_maps_to_io_with_the_same_kind() {
    let error = IoError::new(IoErrorKind::NotFound, "missing");

    assert_eq!(DecoderError::from(error), DecoderError::Io(IoErrorKind::NotFound));
}

#[test]
fn toml_error_maps_to_manifest() {
    let error = toml::from_str::<toml::Value>("not valid toml [[[").unwrap_err();

    assert_eq!(DecoderError::from(error), DecoderError::Manifest);
}

#[test]
fn mime_parse_error_maps_to_invalid_mime_type() {
    let error = "".parse::<Mime>().unwrap_err();

    assert_eq!(DecoderError::from(error), DecoderError::InvalidMimeType);
}

#[test]
fn every_variant_maps_to_the_documented_error_kind() {
    let cases = [
        (DecoderError::Load, ErrorKind::NotFound),
        (DecoderError::Symbol, ErrorKind::AbiMismatch),
        (
            DecoderError::AbiMismatch { got: 1, expected: 2 },
            ErrorKind::AbiMismatch,
        ),
        (DecoderError::Failed(-1), ErrorKind::Unexpected),
        (DecoderError::InvalidResponse, ErrorKind::InvalidEntry),
        (DecoderError::Io(IoErrorKind::NotFound), ErrorKind::ReadFailed),
        (DecoderError::Manifest, ErrorKind::InvalidEntry),
        (DecoderError::DuplicateFormat("deb".to_owned()), ErrorKind::InvalidEntry),
        (DecoderError::UnknownFormat("zst".to_owned()), ErrorKind::NotFound),
        (DecoderError::InvalidMimeType, ErrorKind::InvalidEntry),
        (DecoderError::NoDecoders, ErrorKind::NotFound),
    ];

    for (error, expected) in cases {
        assert_eq!(ErrorKind::from(error), expected);
    }
}
