// SPDX-FileCopyrightText: 2026 JustPav
// SPDX-FileCopyrightText: 2026 SmoothTeam
//
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

use composefs::fsverity::FsVerityHashValue;

use tempfile::TempDir;

use upac::composefs::repository::ObjectID;
use upac::database::record::DeployRecord;
use upac::orchestrator::Context;
use upac::orchestrator::stage::{Stage, StageResult};

use upac_abi::hook::{CancelToken, ProgressEventBuilder};

use crate::target::TargetSysroot;
use crate::types::{ConfigDigest, GenesisInput, PrefixDigest};

use super::WriteDeployRecordStage;

fn genesis_input(pinned: bool) -> GenesisInput {
    GenesisInput {
        source: String::new(),
        empty_config: false,
        pinned,
        boot_plugin: None,
    }
}

#[test]
fn run_writes_a_deploy_record_readable_back_from_disk() {
    let scratch = TempDir::new().unwrap();
    let target = TargetSysroot::for_testing(scratch.path().to_path_buf()).unwrap();

    let mut context = Context::new();
    context.put(target);
    context.put(genesis_input(true));
    context.put(PrefixDigest(ObjectID::EMPTY));
    context.put(ConfigDigest(ObjectID::EMPTY));

    let cancel = CancelToken::new();
    let progress = ProgressEventBuilder::new(0);

    let (_, result, _guard) = WriteDeployRecordStage.run(&mut context, &cancel, progress).unwrap();

    assert!(matches!(result, StageResult::Advance));

    let target = context.get::<TargetSysroot>().unwrap();
    let deploy_dir = target.deploy_dir(&ObjectID::EMPTY.to_hex());

    let record = DeployRecord::read(&deploy_dir).unwrap();
    assert_eq!(record.prefix_digest, ObjectID::EMPTY.to_hex());
    assert_eq!(record.subject, "genesis");
    assert_eq!(record.message, None);
    assert!(record.pinned);
    assert!(record.config_history.is_empty());
    assert_eq!(record.working_config, ObjectID::EMPTY.to_hex());
}

#[test]
fn run_fails_when_target_missing_from_context() {
    let mut context = Context::new();
    context.put(genesis_input(false));
    context.put(PrefixDigest(ObjectID::EMPTY));
    context.put(ConfigDigest(ObjectID::EMPTY));

    let cancel = CancelToken::new();
    let progress = ProgressEventBuilder::new(0);

    let result = WriteDeployRecordStage.run(&mut context, &cancel, progress);

    assert!(result.is_err());
}
