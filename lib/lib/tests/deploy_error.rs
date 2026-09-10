// SPDX-FileCopyrightText: 2026 JustPav
// SPDX-FileCopyrightText: 2026 SmoothTeam
//
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

use std::io::{Error as IoError, ErrorKind as IoErrorKind};

use anyhow::anyhow;

use nix::errno::Errno;

use rsblkid::probe::{ProbeBuilderError, ProbeError};

use rsmount::errors::MountInfoError;

use upac::deploy::error::SysrootError;

use upac_abi::error::ErrorKind;

#[test]
fn mount_info_error_maps_to_mount_info_unavailable() {
    let error = MountInfoError::Creation("boom".to_owned());

    assert_eq!(SysrootError::from(error), SysrootError::MountInfoUnavailable);
}

#[test]
fn probe_builder_error_maps_to_probe_unavailable() {
    let error = ProbeBuilderError::Required("scan_device".to_owned());

    assert_eq!(SysrootError::from(error), SysrootError::ProbeUnavailable);
}

#[test]
fn probe_error_maps_to_probe_unavailable() {
    let error = ProbeError::Config("bad config".to_owned());

    assert_eq!(SysrootError::from(error), SysrootError::ProbeUnavailable);
}

#[test]
fn io_error_maps_to_sysroot_dir_unavailable() {
    let error = IoError::new(IoErrorKind::PermissionDenied, "denied");

    assert_eq!(SysrootError::from(error), SysrootError::SysrootDirUnavailable);
}

#[test]
fn errno_maps_to_the_system_variant_with_the_same_errno() {
    assert_eq!(SysrootError::from(Errno::ENOSPC), SysrootError::System(Errno::ENOSPC));
}

#[test]
fn anyhow_error_maps_to_current_prefix_digest_not_found() {
    let error = anyhow!("no current prefix digest");

    assert_eq!(SysrootError::from(error), SysrootError::CurrentPrefixDigestNotFound);
}

#[test]
fn every_variant_maps_to_the_documented_error_kind() {
    let cases = [
        (SysrootError::MountInfoUnavailable, ErrorKind::Unexpected),
        (SysrootError::RootDeviceNotFound, ErrorKind::NotFound),
        (SysrootError::CanonicalDeviceNotFound, ErrorKind::NotFound),
        (SysrootError::SysrootDirUnavailable, ErrorKind::NotFound),
        (SysrootError::DeploysDirNotFound, ErrorKind::NotFound),
        (SysrootError::RepoDirNotFound, ErrorKind::NotFound),
        (SysrootError::ProbeUnavailable, ErrorKind::Unexpected),
        (SysrootError::FilesystemTypeNotFound, ErrorKind::NotFound),
        (SysrootError::CurrentPrefixDigestNotFound, ErrorKind::NotFound),
        (SysrootError::EspNotFound, ErrorKind::NotFound),
        (SysrootError::System(Errno::EIO), ErrorKind::Unexpected),
    ];

    for (error, expected) in cases {
        assert_eq!(ErrorKind::from(error), expected);
    }
}
