// SPDX-FileCopyrightText: 2026 JustPav
// SPDX-FileCopyrightText: 2026 SmoothTeam
//
// SPDX-License-Identifier: GPL-3.0-only

use std::fmt::{Display, Formatter, Result as FmtResult};

use i18n_embed_fl::fl;

use upac_setup::error::SetupError;
use upac_setup::genesis::GenesisStage;

use crate::locale::LOADER;

#[cfg(test)]
#[path = "../tests/inline/errors.rs"]
mod tests;

#[derive(Debug)]
pub struct LocalizedSetupError(pub (GenesisStage, SetupError));

impl Display for LocalizedSetupError {
    fn fmt(&self, formatter: &mut Formatter<'_>) -> FmtResult {
        let (stage, error) = &self.0;

        write!(formatter, "{}: ", LOADER.get(stage.stage_key()))?;

        match error {
            SetupError::Common(error) => {
                write!(formatter, "{} ({error:?})", fl!(LOADER, "err-common"))
            }
            SetupError::Mount(errno) => {
                write!(formatter, "{} ({errno})", fl!(LOADER, "err-mount"))
            }
            SetupError::Repo(error) => {
                write!(formatter, "{} ({error:?})", fl!(LOADER, "err-repo"))
            }
            SetupError::Database(error) => {
                write!(formatter, "{} ({error:?})", fl!(LOADER, "err-database"))
            }
            SetupError::DeployRecord(error) => {
                write!(formatter, "{} ({error:?})", fl!(LOADER, "err-deploy-record"))
            }
            SetupError::Boot(error) => {
                write!(formatter, "{} ({error:?})", fl!(LOADER, "err-boot"))
            }
            SetupError::BootPlugin(error) => {
                write!(formatter, "{} ({error:?})", fl!(LOADER, "err-boot-plugin"))
            }
            SetupError::Io(kind) => {
                write!(formatter, "{} ({kind:?})", fl!(LOADER, "err-io"))
            }
            SetupError::NoSpaceLeft => formatter.write_str(&fl!(LOADER, "err-no-space-left")),
            SetupError::NotBlockDevice => formatter.write_str(&fl!(LOADER, "err-not-block-device")),
            SetupError::MkfsFailed => formatter.write_str(&fl!(LOADER, "err-mkfs-failed")),
            SetupError::WipeFailed => formatter.write_str(&fl!(LOADER, "err-wipe-failed")),
            SetupError::PartitionNotReady => formatter.write_str(&fl!(LOADER, "err-partition-not-ready")),
            SetupError::InvalidPartitionLayout => formatter.write_str(&fl!(LOADER, "err-invalid-partition-layout")),
            SetupError::InvalidFormatParams => formatter.write_str(&fl!(LOADER, "err-invalid-format-params")),
            SetupError::RereadFailed(errno) => {
                write!(formatter, "{} ({errno})", fl!(LOADER, "err-reread-failed"))
            }
            SetupError::ComposefsSetupRootUnitNotFound => {
                formatter.write_str(&fl!(LOADER, "err-composefs-setup-root-unit-not-found"))
            }
            SetupError::Unexpected => formatter.write_str(&fl!(LOADER, "err-unexpected")),
        }
    }
}

impl std::error::Error for LocalizedSetupError {}
