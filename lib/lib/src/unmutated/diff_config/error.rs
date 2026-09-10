// SPDX-FileCopyrightText: 2026 JustPav
// SPDX-FileCopyrightText: 2026 SmoothTeam
//
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

use upac_abi::error::ErrorKind;

use crate::composefs::error::RepoError;
use crate::database::error::{ConfigDigestResolveError, DatabaseError, DeployRecordsError};
use crate::deploy::error::SysrootError;
use crate::errors::{
    CommonError, common_error_from, config_digest_resolve_error_from, database_error_from, deploy_records_error_from,
    lock_error_from, repo_error_from, sysroot_error_from,
};
use crate::lock::LockError;

#[cfg(test)]
#[path = "../../../tests/inline/unmutated_diff_config_error.rs"]
mod tests;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DiffConfigError {
    Common(CommonError),
    ConfigDigestNotFound(String),
}

common_error_from!(DiffConfigError);

database_error_from!(DiffConfigError);

deploy_records_error_from!(DiffConfigError);

config_digest_resolve_error_from!(DiffConfigError);

repo_error_from!(DiffConfigError);

sysroot_error_from!(DiffConfigError);

lock_error_from!(DiffConfigError);

impl From<DiffConfigError> for ErrorKind {
    fn from(error: DiffConfigError) -> Self {
        match error {
            DiffConfigError::Common(common_error) => common_error.into(),
            DiffConfigError::ConfigDigestNotFound(_) => ErrorKind::NotFound,
        }
    }
}
