// SPDX-FileCopyrightText: 2026 JustPav
// SPDX-FileCopyrightText: 2026 SmoothTeam
//
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

use upac_abi::error::ErrorKind;

use crate::composefs::error::RepoError;
use crate::database::error::DatabaseError;
use crate::deploy::error::SysrootError;
use crate::errors::{
    CommonError, common_error_from, database_error_from, lock_error_from, regex_error_from, repo_error_from,
    sysroot_error_from,
};
use crate::lock::LockError;

#[cfg(test)]
#[path = "../../../tests/inline/unmutated_search_in_package_files_error.rs"]
mod tests;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SearchInPackageFilesError {
    Common(CommonError),
    InvalidSearchPattern(String),
}

common_error_from!(SearchInPackageFilesError);

regex_error_from!(SearchInPackageFilesError);

database_error_from!(SearchInPackageFilesError);

repo_error_from!(SearchInPackageFilesError);

sysroot_error_from!(SearchInPackageFilesError);

lock_error_from!(SearchInPackageFilesError);

impl From<SearchInPackageFilesError> for ErrorKind {
    fn from(error: SearchInPackageFilesError) -> Self {
        match error {
            SearchInPackageFilesError::Common(common_error) => common_error.into(),
            SearchInPackageFilesError::InvalidSearchPattern(_) => ErrorKind::InvalidEntry,
        }
    }
}
