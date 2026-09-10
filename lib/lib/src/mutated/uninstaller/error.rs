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
#[path = "../../../tests/inline/mutated_uninstaller_error.rs"]
mod tests;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum UninstallError {
    PackageNotFound,
    Common(CommonError),
}

common_error_from!(UninstallError);

database_error_from!(UninstallError);

sysroot_error_from!(UninstallError);

lock_error_from!(UninstallError);

boot_error_from!(UninstallError);

boot_plugin_error_from!(UninstallError);

repo_error_from!(UninstallError);

deploy_record_error_from!(UninstallError);

impl From<UninstallError> for ErrorKind {
    fn from(error: UninstallError) -> Self {
        match error {
            UninstallError::PackageNotFound => ErrorKind::NotFound,
            UninstallError::Common(common_error) => common_error.into(),
        }
    }
}
