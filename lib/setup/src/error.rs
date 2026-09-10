// SPDX-FileCopyrightText: 2026 JustPav
// SPDX-FileCopyrightText: 2026 SmoothTeam
//
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

use std::io::{Error as IoError, ErrorKind as IoErrorKind};

use anyhow::Error as AnyhowError;

use gptman::Error as GptError;
use gptman::linux::BlockError as GptBlockError;

use nix::errno::Errno;

use upac::boot::error::BootError;
use upac::composefs::error::RepoError;
use upac::database::error::{DatabaseError, DeployRecordError};
use upac::errors::CommonError;
use upac::lock::LockError;
use upac::plugin::boot::error::BootPluginError;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SetupError {
    Common(CommonError),
    Mount(Errno),
    Repo(RepoError),
    Database(DatabaseError),
    DeployRecord(DeployRecordError),
    Boot(BootError),
    BootPlugin(BootPluginError),
    Io(IoErrorKind),
    NoSpaceLeft,
    NotBlockDevice,
    MkfsFailed,
    WipeFailed,
    PartitionNotReady,
    InvalidPartitionLayout,
    InvalidFormatParams,
    RereadFailed(Errno),
    ComposefsSetupRootUnitNotFound,
    Unexpected,
}

impl From<CommonError> for SetupError {
    fn from(error: CommonError) -> Self {
        SetupError::Common(error)
    }
}

impl From<LockError> for SetupError {
    fn from(error: LockError) -> Self {
        SetupError::Common(CommonError::Lock(error))
    }
}

impl From<Errno> for SetupError {
    fn from(errno: Errno) -> Self {
        SetupError::Mount(errno)
    }
}

impl From<RepoError> for SetupError {
    fn from(error: RepoError) -> Self {
        SetupError::Repo(error)
    }
}

impl From<DatabaseError> for SetupError {
    fn from(error: DatabaseError) -> Self {
        SetupError::Database(error)
    }
}

impl From<DeployRecordError> for SetupError {
    fn from(error: DeployRecordError) -> Self {
        SetupError::DeployRecord(error)
    }
}

impl From<BootError> for SetupError {
    fn from(error: BootError) -> Self {
        SetupError::Boot(error)
    }
}

impl From<BootPluginError> for SetupError {
    fn from(error: BootPluginError) -> Self {
        SetupError::BootPlugin(error)
    }
}

impl From<IoError> for SetupError {
    fn from(error: IoError) -> Self {
        SetupError::Io(error.kind())
    }
}

impl From<GptError> for SetupError {
    fn from(error: GptError) -> Self {
        match error {
            GptError::Io(io_error) => SetupError::Io(io_error.kind()),
            GptError::NoSpaceLeft => SetupError::NoSpaceLeft,
            GptError::InvalidPartitionBoundaries => SetupError::InvalidPartitionLayout,
            _ => SetupError::Unexpected,
        }
    }
}

impl From<GptBlockError> for SetupError {
    fn from(error: GptBlockError) -> Self {
        match error {
            GptBlockError::Metadata(io_error) => SetupError::Io(io_error.kind()),
            GptBlockError::NotBlock => SetupError::NotBlockDevice,
            GptBlockError::RereadTable(errno) => SetupError::RereadFailed(errno),
            _ => SetupError::Unexpected,
        }
    }
}

impl From<AnyhowError> for SetupError {
    fn from(_: AnyhowError) -> Self {
        SetupError::Unexpected
    }
}
