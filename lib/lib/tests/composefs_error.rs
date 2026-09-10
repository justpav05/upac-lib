// SPDX-FileCopyrightText: 2026 JustPav
// SPDX-FileCopyrightText: 2026 SmoothTeam
//
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

use std::ffi::OsStr;
use std::io::{Error as IoError, ErrorKind as IoErrorKind};

use anyhow::anyhow;

use composefs::fsverity::Algorithm;
use composefs::generic_tree::ImageError;
use composefs::repository::RepositoryOpenError;

use hex::FromHexError;

use upac::composefs::error::RepoError;

use upac_abi::error::ErrorKind;

#[test]
fn hex_error_maps_to_invalid_digest() {
    let error = FromHexError::OddLength;

    assert_eq!(RepoError::from(error), RepoError::InvalidDigest);
}

#[test]
fn io_error_maps_by_kind() {
    assert_eq!(
        RepoError::from(IoError::new(IoErrorKind::NotFound, "missing")),
        RepoError::NotFound
    );
    assert_eq!(
        RepoError::from(IoError::new(IoErrorKind::PermissionDenied, "denied")),
        RepoError::AccessDenied
    );
    assert_eq!(RepoError::from(IoError::other("other")), RepoError::Unexpected);
}

#[test]
fn repository_open_error_maps_every_variant() {
    assert_eq!(
        RepoError::from(RepositoryOpenError::MetadataMissing),
        RepoError::NotInitialized
    );
    assert_eq!(
        RepoError::from(RepositoryOpenError::OldFormatRepository),
        RepoError::NotInitialized
    );
    assert_eq!(
        RepoError::from(RepositoryOpenError::MetadataInvalid(
            serde_json::from_str::<serde_json::Value>("not json").unwrap_err()
        )),
        RepoError::Corrupted
    );
    assert_eq!(
        RepoError::from(RepositoryOpenError::AlgorithmMismatch {
            found: Algorithm::Sha256 { lg_blocksize: 12 },
            expected: Algorithm::Sha512 { lg_blocksize: 12 },
        }),
        RepoError::AlgorithmMismatch
    );
    assert_eq!(
        RepoError::from(RepositoryOpenError::UnsupportedVersion { found: 99 }),
        RepoError::UnsupportedVersion
    );
    assert_eq!(
        RepoError::from(RepositoryOpenError::IncompatibleFeatures(vec!["unknown".to_owned()])),
        RepoError::IncompatibleFeatures
    );
    assert_eq!(
        RepoError::from(RepositoryOpenError::Io(IoError::new(IoErrorKind::NotFound, "missing"))),
        RepoError::NotFound
    );
}

#[test]
fn image_error_maps_every_variant() {
    assert_eq!(
        RepoError::from(ImageError::InvalidFilename(Box::<OsStr>::from(OsStr::new("..")))),
        RepoError::InvalidPath
    );
    assert_eq!(
        RepoError::from(ImageError::NotFound(Box::<OsStr>::from(OsStr::new("missing")))),
        RepoError::NotFound
    );
    assert_eq!(
        RepoError::from(ImageError::NotADirectory(Box::<OsStr>::from(OsStr::new("file")))),
        RepoError::NotADirectory
    );
    assert_eq!(
        RepoError::from(ImageError::IsADirectory(Box::<OsStr>::from(OsStr::new("dir")))),
        RepoError::IsADirectory
    );
    assert_eq!(
        RepoError::from(ImageError::IsNotRegular(Box::<OsStr>::from(OsStr::new("special")))),
        RepoError::NotRegularFile
    );
    assert_eq!(
        RepoError::from(ImageError::LeafIdOutOfBounds(1, 0)),
        RepoError::Unexpected
    );
    assert_eq!(
        RepoError::from(ImageError::OrphanedLeaves(vec![1])),
        RepoError::Unexpected
    );
}

#[test]
fn anyhow_error_maps_to_unexpected() {
    assert_eq!(RepoError::from(anyhow!("boom")), RepoError::Unexpected);
}

#[test]
fn every_variant_maps_to_the_documented_error_kind() {
    let cases = [
        (RepoError::NotInitialized, ErrorKind::NotInitialized),
        (RepoError::Corrupted, ErrorKind::ReadFailed),
        (RepoError::AlgorithmMismatch, ErrorKind::Unexpected),
        (RepoError::UnsupportedVersion, ErrorKind::Unexpected),
        (RepoError::IncompatibleFeatures, ErrorKind::Unexpected),
        (RepoError::NotFound, ErrorKind::NotFound),
        (RepoError::AccessDenied, ErrorKind::PermissionDenied),
        (RepoError::InvalidPath, ErrorKind::InvalidPath),
        (RepoError::InvalidDigest, ErrorKind::InvalidPath),
        (RepoError::NotADirectory, ErrorKind::InvalidEntry),
        (RepoError::IsADirectory, ErrorKind::InvalidEntry),
        (RepoError::NotRegularFile, ErrorKind::InvalidEntry),
        (RepoError::NotASymlink, ErrorKind::InvalidEntry),
        (RepoError::Cancelled, ErrorKind::Cancelled),
        (RepoError::Unexpected, ErrorKind::Unexpected),
    ];

    for (error, expected) in cases {
        assert_eq!(ErrorKind::from(error), expected);
    }
}
