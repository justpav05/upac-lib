// SPDX-FileCopyrightText: 2026 JustPav
// SPDX-FileCopyrightText: 2026 SmoothTeam
//
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

use upac_types::entry::FileEntry;
use upac_types::package::PackageMeta;

use super::error::DatabaseError;
use super::files::FileStore;
use super::meta::MetaStore;

pub struct FileAttribution {
    pub package_meta: PackageMeta,
    pub file_entry: FileEntry,
}

pub trait FileAttribute: FileStore + MetaStore {
    fn attribute_file(&self, path: &str) -> Result<Option<FileAttribution>, DatabaseError> {
        let Some(uuid) = self.find_file_owner(path)? else {
            return Ok(None);
        };
        let Some(package_meta) = self.get_package_meta(uuid)? else {
            return Ok(None);
        };
        let Some(file_entry) = self
            .list_package_files(uuid)?
            .into_iter()
            .find(|entry| entry.path == path)
        else {
            return Ok(None);
        };

        Ok(Some(FileAttribution {
            package_meta,
            file_entry,
        }))
    }
}

impl<T: FileStore + MetaStore> FileAttribute for T {}
