// SPDX-FileCopyrightText: 2026 JustPav
// SPDX-FileCopyrightText: 2026 SmoothTeam
//
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

use std::collections::HashMap;
use std::fs::write;

use tempfile::{Builder, TempDir};
use upac::plugin::decoder::error::DecoderError;
use upac::plugin::decoder::manifest::load_decoder_manifests;
use upac::plugin::decoder::triggers::build_trigger_table;
use upac::scripts::error::HookError;
use upac::scripts::file::HookFile;

fn scratch_dir(name: &str) -> TempDir {
    Builder::new().prefix(name).tempdir().unwrap()
}

fn hook_file(priority: i32, triggers: &[(&str, &[&str])]) -> HookFile {
    let mut triggers_map = HashMap::new();
    for (format, names) in triggers {
        triggers_map.insert(format.to_string(), names.iter().map(|name| name.to_string()).collect());
    }

    HookFile {
        priority,
        critical: false,
        operation: None,
        timing: None,
        triggers: triggers_map,
        steps: Vec::new(),
    }
}

#[test]
fn build_trigger_table_matches_single_hook() {
    let hooks = vec![hook_file(0, &[("deb", &["postinst"])])];

    let table = build_trigger_table(&hooks, "deb").unwrap();

    assert_eq!(table.len(), 1);
    assert_eq!(table[0].name, "postinst");
    assert_eq!(table[0].hook_id, 0);
}

#[test]
fn build_trigger_table_ignores_other_formats() {
    let hooks = vec![hook_file(0, &[("rpm", &["posttrans"])])];

    let table = build_trigger_table(&hooks, "deb").unwrap();

    assert!(table.is_empty());
}

#[test]
fn build_trigger_table_picks_higher_priority_hook() {
    let hooks = vec![
        hook_file(1, &[("deb", &["postinst"])]),
        hook_file(5, &[("deb", &["postinst"])]),
    ];

    let table = build_trigger_table(&hooks, "deb").unwrap();

    assert_eq!(table.len(), 1);
    assert_eq!(table[0].hook_id, 1);
}

#[test]
fn build_trigger_table_fails_on_priority_tie() {
    let hooks = vec![
        hook_file(3, &[("deb", &["postinst"])]),
        hook_file(3, &[("deb", &["postinst"])]),
    ];

    let result = build_trigger_table(&hooks, "deb");

    assert!(matches!(result, Err(HookError::TriggerConflict(name)) if name == "postinst"));
}

#[test]
fn build_trigger_table_keeps_distinct_names_independent() {
    let hooks = vec![hook_file(0, &[("deb", &["postinst", "postrm"])])];

    let table = build_trigger_table(&hooks, "deb").unwrap();
    let mut names: Vec<&str> = table.iter().map(|entry| entry.name.as_str()).collect();
    names.sort();

    assert_eq!(names, vec!["postinst", "postrm"]);
}

#[test]
fn load_decoder_manifests_collects_distinct_formats() {
    let dir = scratch_dir("distinct-formats");
    write(
        dir.path().join("deb.decoder"),
        "format = \"deb\"\nextensions = [\"deb\"]\nlibrary = \"libupac-deb.so\"\nmime = \"application/vnd.debian.binary-package\"\n",
    )
    .unwrap();
    write(
        dir.path().join("rpm.decoder"),
        "format = \"rpm\"\nextensions = [\"rpm\"]\nlibrary = \"libupac-rpm.so\"\nmime = \"application/x-rpm\"\n",
    )
    .unwrap();

    let manifests = load_decoder_manifests(dir.path().to_str().unwrap(), "decoder").unwrap();

    assert_eq!(manifests.len(), 2);
    assert_eq!(manifests["deb"].library, "libupac-deb.so");
    assert_eq!(manifests["rpm"].extensions, vec!["rpm".to_owned()]);
}

#[test]
fn load_decoder_manifests_ignores_non_matching_extension() {
    let dir = scratch_dir("ignore-extension");
    write(
        dir.path().join("deb.decoder"),
        "format = \"deb\"\nextensions = [\"deb\"]\nlibrary = \"libupac-deb.so\"\nmime = \"application/vnd.debian.binary-package\"\n",
    )
    .unwrap();
    write(dir.path().join("README.md"), b"not a manifest").unwrap();

    let manifests = load_decoder_manifests(dir.path().to_str().unwrap(), "decoder").unwrap();

    assert_eq!(manifests.len(), 1);
}

#[test]
fn load_decoder_manifests_fails_on_duplicate_format() {
    let dir = scratch_dir("duplicate-format");
    write(
        dir.path().join("a.decoder"),
        "format = \"deb\"\nextensions = [\"deb\"]\nlibrary = \"libupac-deb-a.so\"\nmime = \"application/vnd.debian.binary-package\"\n",
    )
    .unwrap();
    write(
        dir.path().join("b.decoder"),
        "format = \"deb\"\nextensions = [\"deb\"]\nlibrary = \"libupac-deb-b.so\"\nmime = \"application/vnd.debian.binary-package\"\n",
    )
    .unwrap();

    let result = load_decoder_manifests(dir.path().to_str().unwrap(), "decoder");

    assert_eq!(result.unwrap_err(), DecoderError::DuplicateFormat("deb".to_owned()));
}

#[test]
fn load_decoder_manifests_treats_a_missing_directory_as_no_manifests() {
    let dir = scratch_dir("missing-dir").path().join("does-not-exist");

    let manifests = load_decoder_manifests(dir.to_str().unwrap(), "decoder").unwrap();

    assert!(manifests.is_empty());
}

#[test]
fn load_decoder_manifests_fails_on_malformed_toml() {
    let dir = scratch_dir("malformed-toml");
    write(dir.path().join("broken.decoder"), "not valid toml [[[").unwrap();

    let result = load_decoder_manifests(dir.path().to_str().unwrap(), "decoder");

    assert_eq!(result.unwrap_err(), DecoderError::Manifest);
}
