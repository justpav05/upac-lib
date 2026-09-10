// SPDX-FileCopyrightText: 2026 JustPav
// SPDX-FileCopyrightText: 2026 SmoothTeam
//
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

use upac_abi::error::ErrorKind;

use super::{CommonError, SearchMetaError};

#[test]
fn regex_error_maps_to_invalid_search_pattern() {
    let invalid_pattern = "(";
    let error = regex::Regex::new(invalid_pattern).unwrap_err();

    assert!(matches!(
        SearchMetaError::from(error),
        SearchMetaError::InvalidSearchPattern(_)
    ));
}

#[test]
fn every_own_variant_maps_to_the_documented_error_kind() {
    let cases = [
        (
            SearchMetaError::Common(CommonError::OutOfMemory),
            ErrorKind::OutOfMemory,
        ),
        (
            SearchMetaError::InvalidSearchPattern("(".to_owned()),
            ErrorKind::InvalidEntry,
        ),
    ];

    for (error, expected) in cases {
        assert_eq!(ErrorKind::from(error), expected);
    }
}
