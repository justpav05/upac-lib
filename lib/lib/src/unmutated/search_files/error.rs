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
#[path = "../../../tests/inline/unmutated_search_files_error.rs"]
mod tests;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SearchFilesError {
    Common(CommonError),
    InvalidSearchPattern(String),
}

common_error_from!(SearchFilesError);

regex_error_from!(SearchFilesError);

database_error_from!(SearchFilesError);

repo_error_from!(SearchFilesError);

sysroot_error_from!(SearchFilesError);

lock_error_from!(SearchFilesError);

impl From<SearchFilesError> for ErrorKind {
    fn from(error: SearchFilesError) -> Self {
        match error {
            SearchFilesError::Common(common_error) => common_error.into(),
            SearchFilesError::InvalidSearchPattern(_) => ErrorKind::InvalidEntry,
        }
    }
}
