// SPDX-FileCopyrightText: 2026 JustPav
// SPDX-FileCopyrightText: 2026 SmoothTeam
//
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

use upac_abi::{CONSTRAINT_ANY, CONSTRAINT_EQUAL, CONSTRAINT_GREATER, CONSTRAINT_LESS};

use upac_decoder_alpm::pkginfo::PkgInfo;

use upac_types::error::DecodeError;
use upac_types::traits::DecodeMeta;

const CHECKSUM: [u8; 32] = [7; 32];

#[test]
fn parses_minimal_pkginfo_with_defaults() {
    let content = "pkgname = foo\npkgver = 1.2.3\n";

    let decoded = PkgInfo(content).decode(CHECKSUM).unwrap();

    assert_eq!(decoded.meta.name, "foo");
    assert_eq!(decoded.meta.version.raw, "1.2.3");
    assert_eq!(decoded.meta.version.epoch, 0);
    assert_eq!(decoded.meta.arch, "any");
    assert_eq!(decoded.meta.maintainer, "");
    assert_eq!(decoded.meta.description, "");
    assert_eq!(decoded.meta.license, None);
    assert_eq!(decoded.meta.url, None);
    assert_eq!(decoded.meta.sha256, CHECKSUM);
    assert!(decoded.dependencies.is_empty());
}

#[test]
fn combines_pkgver_and_pkgrel_into_the_raw_version() {
    let content = "pkgname = foo\npkgver = 1.2.3\npkgrel = 2\n";

    let decoded = PkgInfo(content).decode(CHECKSUM).unwrap();

    assert_eq!(decoded.meta.version.raw, "1.2.3-2");
}

#[test]
fn parses_epoch_separately_from_the_version() {
    let content = "pkgname = foo\npkgver = 1.2.3\nepoch = 2\n";

    let decoded = PkgInfo(content).decode(CHECKSUM).unwrap();

    assert_eq!(decoded.meta.version.epoch, 2);
    assert_eq!(decoded.meta.version.raw, "1.2.3");
}

#[test]
fn parses_all_fields_and_ignores_comments_and_blank_lines() {
    let content = "# a comment\n\npkgname = foo\npkgver = 1.2.3\narch = x86_64\npkgdesc = A test package\nurl = \
                   https://example.com\npackager = Jane <jane@example.com>\nlicense = MIT\nsize = 4096\n";

    let decoded = PkgInfo(content).decode(CHECKSUM).unwrap();

    assert_eq!(decoded.meta.arch, "x86_64");
    assert_eq!(decoded.meta.description, "A test package");
    assert_eq!(decoded.meta.url, Some("https://example.com".to_owned()));
    assert_eq!(decoded.meta.maintainer, "Jane <jane@example.com>");
    assert_eq!(decoded.meta.license, Some("MIT".to_owned()));
    assert_eq!(decoded.meta.installed_size, 4096);
}

#[test]
fn missing_pkgname_is_malformed() {
    let content = "pkgver = 1.2.3\n";

    let result = PkgInfo(content).decode(CHECKSUM);

    assert_eq!(result.unwrap_err(), DecodeError::MalformedMetadata);
}

#[test]
fn missing_pkgver_is_malformed() {
    let content = "pkgname = foo\n";

    let result = PkgInfo(content).decode(CHECKSUM);

    assert_eq!(result.unwrap_err(), DecodeError::MalformedMetadata);
}

#[test]
fn parses_dependencies_with_every_constraint_operator() {
    let content = "pkgname = foo\npkgver = 1.2.3\ndepend = bash\ndepend = glibc>=2.36\ndepend = openssl<=3\ndepend = \
                   python=3.12\ndepend = zlib<2\ndepend = curl>7\n";

    let decoded = PkgInfo(content).decode(CHECKSUM).unwrap();

    let dependencies = decoded.dependencies;
    assert_eq!(dependencies.len(), 6);

    assert_eq!(dependencies[0].name, "bash");
    assert_eq!(dependencies[0].constraint, CONSTRAINT_ANY);

    assert_eq!(dependencies[1].name, "glibc");
    assert_eq!(dependencies[1].constraint, CONSTRAINT_GREATER | CONSTRAINT_EQUAL);
    assert_eq!(dependencies[1].version.raw, "2.36");

    assert_eq!(dependencies[2].name, "openssl");
    assert_eq!(dependencies[2].constraint, CONSTRAINT_LESS | CONSTRAINT_EQUAL);
    assert_eq!(dependencies[2].version.raw, "3");

    assert_eq!(dependencies[3].name, "python");
    assert_eq!(dependencies[3].constraint, CONSTRAINT_EQUAL);
    assert_eq!(dependencies[3].version.raw, "3.12");

    assert_eq!(dependencies[4].name, "zlib");
    assert_eq!(dependencies[4].constraint, CONSTRAINT_LESS);
    assert_eq!(dependencies[4].version.raw, "2");

    assert_eq!(dependencies[5].name, "curl");
    assert_eq!(dependencies[5].constraint, CONSTRAINT_GREATER);
    assert_eq!(dependencies[5].version.raw, "7");
}

#[test]
fn parses_a_dependency_version_with_its_own_epoch() {
    let content = "pkgname = foo\npkgver = 1.2.3\ndepend = python>=2:3.10\n";

    let decoded = PkgInfo(content).decode(CHECKSUM).unwrap();

    assert_eq!(decoded.dependencies[0].version.epoch, 2);
    assert_eq!(decoded.dependencies[0].version.raw, "3.10");
}
