// SPDX-FileCopyrightText: 2026 JustPav
// SPDX-FileCopyrightText: 2026 SmoothTeam
//
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

use upac_abi::error::ErrorKind;

use crate::boot::error::BootError;
use crate::composefs::error::RepoError;
use crate::database::error::{ConfigDigestResolveError, DatabaseError, DeployRecordError, DeployRecordsError};
use crate::deploy::error::SysrootError;
use crate::errors::{
    CommonError, boot_error_from, boot_plugin_error_from, common_error_from, config_digest_resolve_error_from,
    database_error_from, deploy_record_error_from, deploy_records_error_from, lock_error_from, repo_error_from,
    sysroot_error_from,
};
use crate::lock::LockError;
use crate::plugin::boot::error::BootPluginError;

#[cfg(test)]
#[path = "../../../tests/inline/mutated_rollback_error.rs"]
mod tests;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RollbackError {
    Common(CommonError),
    ConfigDigestNotFound(String),
}

common_error_from!(RollbackError);

database_error_from!(RollbackError);

sysroot_error_from!(RollbackError);

lock_error_from!(RollbackError);

boot_error_from!(RollbackError);

boot_plugin_error_from!(RollbackError);

repo_error_from!(RollbackError);

deploy_record_error_from!(RollbackError);

deploy_records_error_from!(RollbackError);

config_digest_resolve_error_from!(RollbackError);

impl From<RollbackError> for ErrorKind {
    fn from(error: RollbackError) -> Self {
        match error {
            RollbackError::Common(common_error) => common_error.into(),
            RollbackError::ConfigDigestNotFound(_) => ErrorKind::NotFound,
        }
    }
}
