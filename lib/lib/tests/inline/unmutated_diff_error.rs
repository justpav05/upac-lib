// SPDX-FileCopyrightText: 2026 JustPav
// SPDX-FileCopyrightText: 2026 SmoothTeam
//
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

use upac_abi::error::ErrorKind;

use super::{CommonError, DiffError};

#[test]
fn every_own_variant_maps_to_the_documented_error_kind() {
    let cases = [
        (DiffError::Common(CommonError::OutOfMemory), ErrorKind::OutOfMemory),
        (
            DiffError::ConfigDigestNotFound("deadbeef".to_owned()),
            ErrorKind::NotFound,
        ),
    ];

    for (error, expected) in cases {
        assert_eq!(ErrorKind::from(error), expected);
    }
}
