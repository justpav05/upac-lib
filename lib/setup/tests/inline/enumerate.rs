// SPDX-FileCopyrightText: 2026 JustPav
// SPDX-FileCopyrightText: 2026 SmoothTeam
//
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

use std::fs::{create_dir_all, write};

use tempfile::TempDir;

use upac::orchestrator::Context;
use upac::orchestrator::stage::{Stage, StageResult};

use upac_abi::hook::{CancelToken, ProgressEventBuilder};

use upac_types::TmpPath;

use crate::types::{
    ConfigTree, GenesisDatabase, PendingPackagePaths, PendingPackages, PrefixTree, ResolvedSourceDir, TotalPackages,
    UnpackerState,
};

use super::EnumeratePackagesStage;

#[test]
fn run_lists_only_files_and_initializes_pipeline_state() {
    let source = TempDir::new().unwrap();
    write(source.path().join("a.pkg.tar.zst"), b"a").unwrap();
    write(source.path().join("b.pkg.tar.zst"), b"b").unwrap();
    create_dir_all(source.path().join("not-a-package")).unwrap();

    let mut context = Context::new();
    context.put(ResolvedSourceDir(source.path().to_path_buf()));

    let cancel = CancelToken::new();
    let progress = ProgressEventBuilder::new(0);

    let (_, result, _guard) = EnumeratePackagesStage.run(&mut context, &cancel, progress).unwrap();

    assert!(matches!(result, StageResult::Advance));

    let total = context.get::<TotalPackages>().unwrap();
    assert_eq!(total.0, 2);

    let pending = context.get::<PendingPackagePaths>().unwrap();
    assert_eq!(pending.0.len(), 2);

    assert!(context.get::<UnpackerState>().is_some());
    assert!(context.get::<TmpPath>().is_some());
    assert!(context.get::<PendingPackages>().unwrap().0.is_empty());
    assert!(context.get::<GenesisDatabase>().is_some());
    assert!(context.get::<PrefixTree>().is_some());
    assert!(context.get::<ConfigTree>().is_some());
}

#[test]
fn run_with_empty_directory_sets_total_to_zero() {
    let source = TempDir::new().unwrap();

    let mut context = Context::new();
    context.put(ResolvedSourceDir(source.path().to_path_buf()));

    let cancel = CancelToken::new();
    let progress = ProgressEventBuilder::new(0);

    EnumeratePackagesStage.run(&mut context, &cancel, progress).unwrap();

    let total = context.get::<TotalPackages>().unwrap();
    assert_eq!(total.0, 0);

    let pending = context.get::<PendingPackagePaths>().unwrap();
    assert!(pending.0.is_empty());
}

#[test]
fn run_fails_when_source_dir_missing_from_context() {
    let mut context = Context::new();

    let cancel = CancelToken::new();
    let progress = ProgressEventBuilder::new(0);

    let result = EnumeratePackagesStage.run(&mut context, &cancel, progress);

    assert!(result.is_err());
}
