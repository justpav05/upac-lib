// SPDX-FileCopyrightText: 2026 JustPav
// SPDX-FileCopyrightText: 2026 SmoothTeam
//
// SPDX-License-Identifier: GPL-3.0-only

use std::io::ErrorKind as IoErrorKind;

use nix::errno::Errno;

use upac::boot::error::BootError;
use upac::composefs::error::RepoError;
use upac::database::error::{DatabaseError, DeployRecordError};
use upac::errors::CommonError;
use upac::plugin::boot::error::BootPluginError;

use upac_setup::error::SetupError;
use upac_setup::genesis::GenesisStage;

use crate::locale;

use super::LocalizedSetupError;

fn localized(stage: GenesisStage, error: SetupError) -> String {
    locale::init_for_test();
    LocalizedSetupError((stage, error)).to_string()
}

#[test]
fn prefixes_the_message_with_the_localized_failing_stage_name() {
    let message = localized(GenesisStage::ImportPackage, SetupError::Unexpected);

    assert_eq!(message, "Importing package: Unexpected error");
}

#[test]
fn common_variant_embeds_debug_detail() {
    let message = localized(GenesisStage::Setup, SetupError::Common(CommonError::PipelineInvalid));

    assert_eq!(message, "Setup: Common subsystem failure (PipelineInvalid)");
}

#[test]
fn mount_variant_embeds_the_errno() {
    let errno = Errno::EIO;
    let message = localized(GenesisStage::Setup, SetupError::Mount(errno));

    assert_eq!(message, format!("Setup: Mount failed ({errno})"));
}

#[test]
fn repo_variant_embeds_debug_detail() {
    let message = localized(GenesisStage::ImportPackage, SetupError::Repo(RepoError::NotFound));

    assert_eq!(message, "Importing package: Repository operation failed (NotFound)");
}

#[test]
fn database_variant_embeds_debug_detail() {
    let message = localized(
        GenesisStage::EmbedDatabase,
        SetupError::Database(DatabaseError::WriteError),
    );

    assert_eq!(
        message,
        "Embedding package database: Database operation failed (WriteError)"
    );
}

#[test]
fn deploy_record_variant_embeds_debug_detail() {
    let message = localized(
        GenesisStage::WriteDeployRecord,
        SetupError::DeployRecord(DeployRecordError::WriteFailed),
    );

    assert_eq!(
        message,
        "Writing deploy record: Deploy record operation failed (WriteFailed)"
    );
}

#[test]
fn boot_variant_embeds_debug_detail() {
    let message = localized(GenesisStage::StageBoot, SetupError::Boot(BootError::NoBootResource));

    assert_eq!(
        message,
        "Staging boot entry: Boot entry staging failed (NoBootResource)"
    );
}

#[test]
fn boot_plugin_variant_embeds_debug_detail() {
    let message = localized(
        GenesisStage::StageBoot,
        SetupError::BootPlugin(BootPluginError::NoClaimant),
    );

    assert_eq!(message, "Staging boot entry: Boot plugin operation failed (NoClaimant)");
}

#[test]
fn io_variant_embeds_the_error_kind() {
    let message = localized(GenesisStage::UnpackPackage, SetupError::Io(IoErrorKind::NotFound));

    assert_eq!(message, "Unpacking package: I/O error (NotFound)");
}

#[test]
fn reread_failed_variant_embeds_the_errno() {
    let errno = Errno::ENOSPC;
    let message = localized(GenesisStage::Setup, SetupError::RereadFailed(errno));

    assert_eq!(
        message,
        format!("Setup: Failed to reread the partition table (device busy?) ({errno})")
    );
}

#[test]
fn no_payload_variants_use_their_fixed_localized_message() {
    let cases = [
        (SetupError::NoSpaceLeft, "No space left on device"),
        (SetupError::NotBlockDevice, "Not a block device"),
        (SetupError::MkfsFailed, "Filesystem creation failed"),
        (
            SetupError::WipeFailed,
            "Failed to wipe the target partition's existing filesystem signature",
        ),
        (
            SetupError::PartitionNotReady,
            "Partition device did not appear in time after partitioning",
        ),
        (
            SetupError::InvalidPartitionLayout,
            "Requested partition sizes don't fit on the disk",
        ),
        (
            SetupError::InvalidFormatParams,
            "Invalid filesystem formatting parameters",
        ),
        (
            SetupError::ComposefsSetupRootUnitNotFound,
            "composefs-setup-root.service not found under source's system/ directory",
        ),
        (SetupError::Unexpected, "Unexpected error"),
    ];

    for (error, expected) in cases {
        let message = localized(GenesisStage::Setup, error);

        assert_eq!(message, format!("Setup: {expected}"));
    }
}
