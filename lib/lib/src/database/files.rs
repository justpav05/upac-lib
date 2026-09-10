// SPDX-FileCopyrightText: 2026 JustPav
// SPDX-FileCopyrightText: 2026 SmoothTeam
//
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

use redb::{ReadableDatabase, ReadableTable, TypeName, Value as RedbValue};

use twox_hash::xxhash3_64::Hasher as XxHasher;

use uuid::Uuid;

use upac_types::codec::RedbCodable;
use upac_types::entry::FileEntry;

use super::error::DatabaseError;
use super::{FILES_UUID_HASH_TABLE, FILES_UUID_TABLE, MemoryDatabase, ReadTransactionExt, ReadableSource};

use crate::layout::database::FILES_ENTRY_TYPE_NAME;

pub trait FileStore {
    fn path_hash(path: &str) -> u64 {
        XxHasher::oneshot(path.as_bytes())
    }

    fn find_file_owner(&self, path: &str) -> Result<Option<Uuid>, DatabaseError>;
    fn list_package_files(&self, uuid: Uuid) -> Result<Vec<FileEntry>, DatabaseError>;
    fn list_files(&self) -> Result<Vec<(Uuid, FileEntry)>, DatabaseError>;
}

pub trait FileStoreMut: FileStore {
    fn insert_package_file(&mut self, uuid: Uuid, entry: &FileEntry) -> Result<(), DatabaseError>;
    fn update_package_file(&mut self, uuid: Uuid, entry: &FileEntry) -> Result<(), DatabaseError>;
    fn remove_package_file(&mut self, uuid: Uuid, path: &str) -> Result<FileEntry, DatabaseError>;
    fn remove_user_file(&mut self, uuid: Uuid, path: &str) -> Result<FileEntry, DatabaseError>;
}

impl<T: ReadableSource> FileStore for T {
    fn find_file_owner(&self, path: &str) -> Result<Option<Uuid>, DatabaseError> {
        let transaction = self.source().begin_read()?;
        let Some(by_path) = transaction.open_table_or_none(FILES_UUID_HASH_TABLE)? else {
            return Ok(None);
        };

        Ok(by_path.get(Self::path_hash(path))?.map(|guard| guard.value()))
    }

    fn list_package_files(&self, uuid: Uuid) -> Result<Vec<FileEntry>, DatabaseError> {
        let transaction = self.source().begin_read()?;
        let Some(files) = transaction.open_table_or_none(FILES_UUID_TABLE)? else {
            return Ok(Vec::new());
        };
        let mut out = Vec::new();

        for entry in files.range((uuid, 0u64)..)? {
            let (key, value) = entry?;
            let (row_uuid, _hash) = key.value();

            if row_uuid != uuid {
                break;
            }

            out.push(value.value().0);
        }

        Ok(out)
    }

    fn list_files(&self) -> Result<Vec<(Uuid, FileEntry)>, DatabaseError> {
        let transaction = self.source().begin_read()?;
        let Some(files) = transaction.open_table_or_none(FILES_UUID_TABLE)? else {
            return Ok(Vec::new());
        };
        let mut out = Vec::new();

        for entry in files.iter()? {
            let (key, value) = entry?;
            let (uuid, _hash) = key.value();

            out.push((uuid, value.value().0));
        }

        Ok(out)
    }
}

impl FileStoreMut for MemoryDatabase {
    fn insert_package_file(&mut self, uuid: Uuid, entry: &FileEntry) -> Result<(), DatabaseError> {
        let hash = Self::path_hash(&entry.path);
        let transaction = self.database.begin_write()?;
        let mut files = transaction.open_table(FILES_UUID_TABLE)?;

        let already_user_owned = match files.get((uuid, hash))? {
            Some(existing) => existing.value().0.is_user,
            None => false,
        };

        if already_user_owned {
            return Ok(());
        }

        files.insert((uuid, hash), StoredFileEntry::from_ref(entry))?;

        drop(files);
        transaction.open_table(FILES_UUID_HASH_TABLE)?.insert(hash, uuid)?;
        transaction.commit()?;

        Ok(())
    }

    fn update_package_file(&mut self, uuid: Uuid, entry: &FileEntry) -> Result<(), DatabaseError> {
        self.insert_package_file(uuid, entry)
    }

    fn remove_package_file(&mut self, uuid: Uuid, path: &str) -> Result<FileEntry, DatabaseError> {
        let hash = Self::path_hash(path);
        let transaction = self.database.begin_write()?;
        let mut files = transaction.open_table(FILES_UUID_TABLE)?;

        let entry = files.get((uuid, hash))?.ok_or(DatabaseError::FileNotFound)?.value().0;

        if entry.is_user {
            return Err(DatabaseError::AccessDenied);
        }

        files.remove((uuid, hash))?;

        drop(files);
        transaction.open_table(FILES_UUID_HASH_TABLE)?.remove(hash)?;
        transaction.commit()?;

        Ok(entry)
    }

    fn remove_user_file(&mut self, uuid: Uuid, path: &str) -> Result<FileEntry, DatabaseError> {
        let hash = Self::path_hash(path);
        let transaction = self.database.begin_write()?;
        let mut files = transaction.open_table(FILES_UUID_TABLE)?;

        let entry = files.get((uuid, hash))?.ok_or(DatabaseError::FileNotFound)?.value().0;

        if !entry.is_user {
            return Err(DatabaseError::AccessDenied);
        }

        files.remove((uuid, hash))?;

        drop(files);
        transaction.open_table(FILES_UUID_HASH_TABLE)?.remove(hash)?;
        transaction.commit()?;

        Ok(entry)
    }
}

#[derive(Debug)]
#[repr(transparent)]
pub(crate) struct StoredFileEntry(pub(crate) FileEntry);

impl StoredFileEntry {
    fn from_ref(entry: &FileEntry) -> &StoredFileEntry {
        unsafe { &*(entry as *const FileEntry as *const StoredFileEntry) }
    }
}

impl RedbValue for StoredFileEntry {
    type AsBytes<'a> = Vec<u8>;
    type SelfType<'a> = StoredFileEntry;

    fn fixed_width() -> Option<usize> {
        None
    }

    fn from_bytes<'a>(data: &'a [u8]) -> StoredFileEntry
    where
        Self: 'a,
    {
        let mut offset = 0;

        StoredFileEntry(FileEntry::redb_decode(data, &mut offset))
    }

    fn as_bytes<'a, 'b: 'a>(value: &'a StoredFileEntry) -> Vec<u8>
    where
        Self: 'b,
    {
        let mut buf = Vec::new();

        value.0.redb_encode(&mut buf);
        buf
    }

    fn type_name() -> TypeName {
        TypeName::new(FILES_ENTRY_TYPE_NAME)
    }
}
