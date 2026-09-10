// SPDX-FileCopyrightText: 2026 JustPav
// SPDX-FileCopyrightText: 2026 SmoothTeam
//
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

use std::path::{Path, PathBuf};

use upac::errors::CommonError;
use upac::orchestrator::error::OrchestratorError;
use upac::orchestrator::{Context, Orchestrator, SequentialOrchestrator};

use upac_abi::hook::{Message, MessageHook};

use upac_macro::{FromStageIndex, StageKey};

use self::deploy::WriteDeployRecordStage;
use self::embed::EmbedDatabaseStage;
use self::entry::StageBootStage;
use self::enumerate::EnumeratePackagesStage;
use self::import::ImportPackageStage;
use self::source::PrepareSourceStage;
use self::system::ImportSystemStage;
use self::unpack::UnpackPackageStage;

use crate::data::{SetupExistingData, SetupWholeDiskData};
use crate::error::SetupError;
use crate::target::TargetSysroot;
use crate::types::GenesisInput;

mod deploy;
mod embed;
mod entry;
mod enumerate;
mod import;
mod source;
mod system;
mod unpack;

macro_rules! ctx_get {
    ($context:expr, $ty:ty) => {
        $context.get::<$ty>().ok_or(upac::errors::CommonError::MissingResult)?
    };
}
pub(crate) use ctx_get;

macro_rules! ctx_take {
    ($context:expr, $ty:ty) => {
        $context.take::<$ty>().ok_or(upac::errors::CommonError::MissingResult)?
    };
}
pub(crate) use ctx_take;

macro_rules! import_if_dir {
    ($repository:expr, $tree:expr, $source:expr, $import_ctx:expr, $cancel:expr) => {
        if $source.is_dir() {
            upac::composefs::file::FileHandle::new(::std::path::PathBuf::new()).import_directory(
                $repository,
                $tree,
                $source,
                $import_ctx,
                $cancel,
                &mut |_| {},
            )?
        } else {
            Vec::new()
        }
    };
}
pub(crate) use import_if_dir;

#[repr(u8)]
#[derive(Debug, Clone, Copy, PartialEq, Eq, FromStageIndex, StageKey)]
pub enum GenesisStage {
    PrepareSource = 0,
    EnumeratePackages = 1,
    UnpackPackage = 2,
    ImportPackage = 3,
    ImportSystem = 4,
    EmbedDatabase = 5,
    WriteDeployRecord = 6,
    StageBoot = 7,
    Setup = 8,
}

impl SetupExistingData<'_> {
    pub fn run(&self) -> Result<(), (GenesisStage, SetupError)> {
        let target = TargetSysroot::new(
            Path::new(self.deploy_device),
            self.deploy_fs,
            Path::new(self.esp_device),
            PathBuf::from(self.mount_point()),
            &self.extra_mounts,
            None,
            None,
            None,
            None,
        )
        .map_err(|error| (GenesisStage::Setup, error))?;

        let mut context = Context::new();
        context.put(Box::new(Message::new(self.hook_message, self.hook_message_context)) as Box<dyn MessageHook>);
        context.put(target);
        context.put(GenesisInput::from(self));

        let orchestrator = SequentialOrchestrator::new(vec![
            Box::new(PrepareSourceStage),
            Box::new(EnumeratePackagesStage),
            Box::new(UnpackPackageStage),
            Box::new(ImportPackageStage),
            Box::new(ImportSystemStage),
            Box::new(EmbedDatabaseStage),
            Box::new(WriteDeployRecordStage),
            Box::new(StageBootStage),
        ]);

        let result = if orchestrator.validate(&context).is_err() {
            Err((GenesisStage::Setup, SetupError::from(CommonError::PipelineInvalid)))
        } else {
            orchestrator
                .run_exclusive(&mut context, self.cancel_token)
                .map_err(|failure| match failure {
                    OrchestratorError::Setup(lock_error) => (GenesisStage::Setup, SetupError::from(lock_error)),
                    OrchestratorError::Stage(index, error) => (GenesisStage::from_stage_index(index), error),
                })
        };

        self.cancel_token.reset();

        result
    }
}

impl SetupWholeDiskData<'_> {
    pub fn run(&self) -> Result<(), (GenesisStage, SetupError)> {
        let target = TargetSysroot::create_whole_disk(self).map_err(|error| (GenesisStage::Setup, error))?;

        let mut context = Context::new();
        context.put(Box::new(Message::new(self.hook_message, self.hook_message_context)) as Box<dyn MessageHook>);
        context.put(target);
        context.put(GenesisInput::from(self));

        let orchestrator = SequentialOrchestrator::new(vec![
            Box::new(PrepareSourceStage),
            Box::new(EnumeratePackagesStage),
            Box::new(UnpackPackageStage),
            Box::new(ImportPackageStage),
            Box::new(ImportSystemStage),
            Box::new(EmbedDatabaseStage),
            Box::new(WriteDeployRecordStage),
            Box::new(StageBootStage),
        ]);

        let result = if orchestrator.validate(&context).is_err() {
            Err((GenesisStage::Setup, SetupError::from(CommonError::PipelineInvalid)))
        } else {
            orchestrator
                .run_exclusive(&mut context, self.cancel_token)
                .map_err(|failure| match failure {
                    OrchestratorError::Setup(lock_error) => (GenesisStage::Setup, SetupError::from(lock_error)),
                    OrchestratorError::Stage(index, error) => (GenesisStage::from_stage_index(index), error),
                })
        };

        self.cancel_token.reset();

        result
    }
}
