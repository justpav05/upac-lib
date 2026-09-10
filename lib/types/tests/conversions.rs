// SPDX-FileCopyrightText: 2026 JustPav
// SPDX-FileCopyrightText: 2026 SmoothTeam
//
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

use upac_abi::package::{CPackageMeta, CVersion};
use upac_types::package::{PackageMeta, Version};

fn sample_version() -> Version {
    Version {
        epoch: 1,
        raw: "2.5.0-3~rc1".to_owned(),
    }
}

#[test]
fn version_c_round_trip_preserves_value() {
    let original = sample_version();

    let c_version = CVersion::from(original.clone());
    let restored = Version::try_from(&c_version).unwrap();

    assert_eq!(restored, original);
    unsafe { c_version.free() };
}

#[test]
fn package_meta_c_round_trip_preserves_value() {
    let original = PackageMeta {
        name: "upac".to_owned(),
        version: sample_version(),
        arch: "x86_64".to_owned(),
        arch_sub: None,
        maintainer: "JustPav".to_owned(),
        description: "package manager".to_owned(),
        license: Some("GPL-3.0-only".to_owned()),
        url: None,
        sha256: [7; 32],
        installed_size: 4096,
    };

    let c_meta = CPackageMeta::from(original.clone());
    let restored = PackageMeta::try_from(&c_meta).unwrap();

    assert_eq!(restored.name, original.name);
    assert_eq!(restored.version, original.version);
    assert_eq!(restored.arch, original.arch);
    assert_eq!(restored.arch_sub, original.arch_sub);
    assert_eq!(restored.maintainer, original.maintainer);
    assert_eq!(restored.description, original.description);
    assert_eq!(restored.license, original.license);
    assert_eq!(restored.url, original.url);
    assert_eq!(restored.sha256, original.sha256);
    assert_eq!(restored.installed_size, original.installed_size);

    unsafe { c_meta.free() };
}
