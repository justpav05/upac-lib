// SPDX-FileCopyrightText: 2026 JustPav
// SPDX-FileCopyrightText: 2026 SmoothTeam
//
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

use anyhow::anyhow;

use upac::boot::error::BootError;

use upac_abi::error::ErrorKind;

#[test]
fn anyhow_error_maps_to_unexpected() {
    assert_eq!(BootError::from(anyhow!("boom")), BootError::Unexpected);
}

#[test]
fn every_variant_maps_to_the_documented_error_kind() {
    let cases = [
        (BootError::NoBootResource, ErrorKind::NotFound),
        (BootError::AmbiguousBootResource, ErrorKind::InvalidEntry),
        (BootError::UnsupportedBootResource, ErrorKind::InvalidEntry),
        (BootError::Unexpected, ErrorKind::Unexpected),
    ];

    for (error, expected) in cases {
        assert_eq!(ErrorKind::from(error), expected);
    }
}
