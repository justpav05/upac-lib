// SPDX-FileCopyrightText: 2026 JustPav
// SPDX-FileCopyrightText: 2026 SmoothTeam
//
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

use std::fs::write;

use tempfile::{Builder, TempDir};

use upac::plugin::boot::error::BootPluginError;
use upac::plugin::boot::manifest::load_boot_plugin_manifests;

fn scratch_dir(name: &str) -> TempDir {
    Builder::new().prefix(name).tempdir().unwrap()
}

#[test]
fn load_boot_plugin_manifests_collects_distinct_names() {
    let dir = scratch_dir("distinct-names");
    write(
        dir.path().join("uki.boot"),
        "name = \"uki\"\nlibrary = \"libupac-uki.so\"\n",
    )
    .unwrap();
    write(
        dir.path().join("grub.boot"),
        "name = \"grub\"\nlibrary = \"libupac-grub.so\"\n",
    )
    .unwrap();

    let manifests = load_boot_plugin_manifests(dir.path().to_str().unwrap(), "boot").unwrap();

    assert_eq!(manifests.len(), 2);
    assert_eq!(manifests["uki"].library, "libupac-uki.so");
    assert_eq!(manifests["grub"].library, "libupac-grub.so");
}

#[test]
fn load_boot_plugin_manifests_ignores_non_matching_extension() {
    let dir = scratch_dir("ignore-extension");
    write(
        dir.path().join("uki.boot"),
        "name = \"uki\"\nlibrary = \"libupac-uki.so\"\n",
    )
    .unwrap();
    write(dir.path().join("README.md"), b"not a manifest").unwrap();

    let manifests = load_boot_plugin_manifests(dir.path().to_str().unwrap(), "boot").unwrap();

    assert_eq!(manifests.len(), 1);
}

#[test]
fn load_boot_plugin_manifests_fails_on_duplicate_name() {
    let dir = scratch_dir("duplicate-name");
    write(
        dir.path().join("a.boot"),
        "name = \"uki\"\nlibrary = \"libupac-uki-a.so\"\n",
    )
    .unwrap();
    write(
        dir.path().join("b.boot"),
        "name = \"uki\"\nlibrary = \"libupac-uki-b.so\"\n",
    )
    .unwrap();

    let result = load_boot_plugin_manifests(dir.path().to_str().unwrap(), "boot");

    assert_eq!(result.unwrap_err(), BootPluginError::DuplicateName("uki".to_owned()));
}

#[test]
fn load_boot_plugin_manifests_fails_on_malformed_toml() {
    let dir = scratch_dir("malformed-toml");
    write(dir.path().join("broken.boot"), "not valid toml [[[").unwrap();

    let result = load_boot_plugin_manifests(dir.path().to_str().unwrap(), "boot");

    assert_eq!(result.unwrap_err(), BootPluginError::Manifest);
}

#[test]
fn load_boot_plugin_manifests_treats_a_missing_directory_as_no_manifests() {
    let dir = scratch_dir("missing-dir").path().join("does-not-exist");

    let manifests = load_boot_plugin_manifests(dir.to_str().unwrap(), "boot").unwrap();

    assert!(manifests.is_empty());
}
