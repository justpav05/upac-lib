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
#[path = "../../../tests/inline/unmutated_search_in_meta_error.rs"]
mod tests;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SearchInMetaError {
    Common(CommonError),
    InvalidSearchPattern(String),
}

common_error_from!(SearchInMetaError);

regex_error_from!(SearchInMetaError);

database_error_from!(SearchInMetaError);

repo_error_from!(SearchInMetaError);

sysroot_error_from!(SearchInMetaError);

lock_error_from!(SearchInMetaError);

impl From<SearchInMetaError> for ErrorKind {
    fn from(error: SearchInMetaError) -> Self {
        match error {
            SearchInMetaError::Common(common_error) => common_error.into(),
            SearchInMetaError::InvalidSearchPattern(_) => ErrorKind::InvalidEntry,
        }
    }
}
