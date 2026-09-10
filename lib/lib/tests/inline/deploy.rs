// SPDX-FileCopyrightText: 2026 JustPav
// SPDX-FileCopyrightText: 2026 SmoothTeam
//
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

use std::fs::create_dir_all;
use std::path::Path;

use tempfile::TempDir;

use crate::database::record::DeployRecord;

use super::Deploy;

fn write_record(deploy_dir: &Path, digest: &str, seq: u64, pinned: bool) {
    let record_dir = deploy_dir.join(digest);
    create_dir_all(&record_dir).unwrap();

    let record = DeployRecord {
        prefix_digest: digest.to_owned(),
        subject: "test".to_owned(),
        message: None,
        seq,
        timestamp: DeployRecord::now_secs(),
        config_history: Vec::new(),
        working_config: String::new(),
        pinned,
    };
    record.write(&record_dir).unwrap();
}

#[test]
fn prune_deploys_removes_nothing_when_total_is_within_retention_depth() {
    let scratch = TempDir::new().unwrap();
    write_record(scratch.path(), "digest-0", 0, false);
    write_record(scratch.path(), "digest-1", 1, false);
    write_record(scratch.path(), "digest-2", 2, false);

    let deploy = Deploy::for_testing(scratch.path().to_path_buf());
    let removed = deploy.prune_deploys().unwrap();

    assert!(removed.is_empty());
    assert!(scratch.path().join("digest-0").is_dir());
    assert!(scratch.path().join("digest-1").is_dir());
    assert!(scratch.path().join("digest-2").is_dir());
}

#[test]
fn prune_deploys_never_removes_a_pinned_deploy_regardless_of_age() {
    let scratch = TempDir::new().unwrap();

    // Oldest of the bunch, would be beyond any realistic retention depth on its own —
    // `pinned: true` must save it anyway.
    write_record(scratch.path(), "digest-oldest-pinned", 0, true);

    for seq in 1..=6 {
        write_record(scratch.path(), &format!("digest-{seq}"), seq, false);
    }

    let deploy = Deploy::for_testing(scratch.path().to_path_buf());
    let removed = deploy.prune_deploys().unwrap();

    assert!(!removed.contains(&"digest-oldest-pinned".to_owned()));
    assert!(scratch.path().join("digest-oldest-pinned").is_dir());
}

#[test]
fn prune_deploys_removes_the_oldest_unpinned_deploy_when_the_total_is_large() {
    let scratch = TempDir::new().unwrap();

    // Comfortably more entries than any sane retention depth would keep, so the single oldest,
    // unpinned deploy is guaranteed to fall outside it regardless of the real (environment-read)
    // `RuntimeSettings::load().gc.retention_depth` value.
    for seq in 0..64 {
        write_record(scratch.path(), &format!("digest-{seq}"), seq, false);
    }

    let deploy = Deploy::for_testing(scratch.path().to_path_buf());
    let removed = deploy.prune_deploys().unwrap();

    assert!(removed.contains(&"digest-0".to_owned()));
    assert!(!scratch.path().join("digest-0").is_dir());

    // The most recent one is always within any positive retention depth.
    assert!(scratch.path().join("digest-63").is_dir());
}
