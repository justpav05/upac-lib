// SPDX-FileCopyrightText: 2026 JustPav
// SPDX-FileCopyrightText: 2026 SmoothTeam
//
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

use upac_abi::error::ErrorKind;

use super::{
    CommonError, ConfigDigestResolveError, DeployRecordError, DeployRecordsError, RollbackError, SysrootError,
};

#[test]
fn every_own_variant_maps_to_the_documented_error_kind() {
    let cases = [
        (RollbackError::Common(CommonError::OutOfMemory), ErrorKind::OutOfMemory),
        (
            RollbackError::ConfigDigestNotFound("deadbeef".to_owned()),
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
        RollbackError::from(error),
        RollbackError::ConfigDigestNotFound("deadbeef".to_owned())
    );
}

#[test]
fn config_digest_resolve_error_records_delegates_to_the_inner_error() {
    let sysroot = ConfigDigestResolveError::Records(DeployRecordsError::Sysroot(SysrootError::MountInfoUnavailable));
    let deploy_record =
        ConfigDigestResolveError::Records(DeployRecordsError::DeployRecord(DeployRecordError::NotFound));

    assert_eq!(
        RollbackError::from(sysroot),
        RollbackError::Common(CommonError::Sysroot(SysrootError::MountInfoUnavailable))
    );
    assert_eq!(
        RollbackError::from(deploy_record),
        RollbackError::Common(CommonError::DeployRecord(DeployRecordError::NotFound))
    );
}
