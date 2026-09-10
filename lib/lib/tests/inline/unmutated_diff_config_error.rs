// SPDX-FileCopyrightText: 2026 JustPav
// SPDX-FileCopyrightText: 2026 SmoothTeam
//
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

use upac_abi::error::ErrorKind;

use super::{CommonError, ConfigDigestResolveError, DeployRecordsError, DiffConfigError, SysrootError};

#[test]
fn every_own_variant_maps_to_the_documented_error_kind() {
    let cases = [
        (
            DiffConfigError::Common(CommonError::OutOfMemory),
            ErrorKind::OutOfMemory,
        ),
        (
            DiffConfigError::ConfigDigestNotFound("deadbeef".to_owned()),
            ErrorKind::NotFound,
        ),
    ];

    for (error, expected) in cases {
        assert_eq!(ErrorKind::from(error), expected);
    }
}

#[test]
fn config_digest_resolve_error_not_found_maps_to_config_digest_not_found() {
    let error = ConfigDigestResolveError::NotFound("deadbeef".to_owned());

    assert_eq!(
        DiffConfigError::from(error),
        DiffConfigError::ConfigDigestNotFound("deadbeef".to_owned())
    );
}

#[test]
fn config_digest_resolve_error_records_delegates_to_the_inner_error() {
    let error = ConfigDigestResolveError::Records(DeployRecordsError::Sysroot(SysrootError::MountInfoUnavailable));

    assert_eq!(
        DiffConfigError::from(error),
        DiffConfigError::Common(CommonError::Sysroot(SysrootError::MountInfoUnavailable))
    );
}
