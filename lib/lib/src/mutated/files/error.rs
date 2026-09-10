// SPDX-FileCopyrightText: 2026 JustPav
// SPDX-FileCopyrightText: 2026 SmoothTeam
//
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

use upac_abi::error::ErrorKind;

use crate::boot::error::BootError;
use crate::composefs::error::RepoError;
use crate::database::error::{DatabaseError, DeployRecordError};
use crate::deploy::error::SysrootError;
use crate::errors::{
    CommonError, boot_error_from, boot_plugin_error_from, common_error_from, database_error_from,
    deploy_record_error_from, lock_error_from, repo_error_from, sysroot_error_from,
};
use crate::lock::LockError;
use crate::plugin::boot::error::BootPluginError;

#[cfg(test)]
#[path = "../../../tests/inline/mutated_files_error.rs"]
mod tests;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum FilesError {
    PackageNotFound,
    Common(CommonError),
}

common_error_from!(FilesError);

database_error_from!(FilesError);

sysroot_error_from!(FilesError);

lock_error_from!(FilesError);

boot_error_from!(FilesError);

repo_error_from!(FilesError);

deploy_record_error_from!(FilesError);

boot_plugin_error_from!(FilesError);

impl From<FilesError> for ErrorKind {
    fn from(error: FilesError) -> Self {
        match error {
            FilesError::PackageNotFound => ErrorKind::NotFound,
            FilesError::Common(common_error) => common_error.into(),
        }
    }
}
