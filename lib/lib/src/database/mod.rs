// SPDX-FileCopyrightText: 2026 JustPav
// SPDX-FileCopyrightText: 2026 SmoothTeam
//
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

use std::io::{Error as IoError, ErrorKind};
use std::path::Path;
use std::sync::{Arc, PoisonError, RwLock};

use redb::{
    Builder, Database as RedbDatabase, Key, ReadOnlyDatabase as RedbReadOnlyDatabase, ReadOnlyTable, ReadTransaction,
    ReadableDatabase, StorageBackend, TableDefinition, TableError, Value,
};

use uuid::Uuid;

use self::error::DatabaseError;
use self::files::StoredFileEntry;
use self::meta::StoredPackageMeta;
use self::triggers::StoredTriggers;

use crate::layout::database::{
    FILES_BY_PATH_TABLE_NAME, FILES_TABLE_NAME, PACKAGES_BY_NAME_TABLE_NAME, PACKAGES_TABLE_NAME,
    PACKAGES_TRIGGERS_TABLE_NAME,
};

pub mod attribution;
pub mod error;
pub mod files;
pub mod meta;
pub mod record;
pub mod triggers;

pub(crate) const PACKAGES_UUID_TABLE: TableDefinition<Uuid, StoredPackageMeta> =
    TableDefinition::new(PACKAGES_TABLE_NAME);
pub(crate) const PACKAGES_HASH_TABLE: TableDefinition<u64, Uuid> = TableDefinition::new(PACKAGES_BY_NAME_TABLE_NAME);
pub(crate) const PACKAGES_TRIGGERS_TABLE: TableDefinition<Uuid, StoredTriggers> =
    TableDefinition::new(PACKAGES_TRIGGERS_TABLE_NAME);

pub(crate) const FILES_UUID_TABLE: TableDefinition<(Uuid, u64), StoredFileEntry> =
    TableDefinition::new(FILES_TABLE_NAME);
pub(crate) const FILES_UUID_HASH_TABLE: TableDefinition<u64, Uuid> = TableDefinition::new(FILES_BY_PATH_TABLE_NAME);

pub trait InMemory {
    fn new_in_memory() -> Result<Self, DatabaseError>
    where
        Self: Sized;

    fn open_in_memory(bytes: Vec<u8>) -> Result<Self, DatabaseError>
    where
        Self: Sized;

    fn into_bytes(self) -> Result<Vec<u8>, DatabaseError>
    where
        Self: Sized;
}

pub trait FromFile {
    fn open_from_file(path: &Path) -> Result<Self, DatabaseError>
    where
        Self: Sized;
}

pub struct MemoryDatabase {
    database: RedbDatabase,
    backend: SharedMemoryBackend,
}

impl InMemory for MemoryDatabase {
    fn new_in_memory() -> Result<Self, DatabaseError> {
        let backend = SharedMemoryBackend::new();
        let database = Builder::new().create_with_backend(backend.clone())?;

        Ok(Self { database, backend })
    }

    fn open_in_memory(bytes: Vec<u8>) -> Result<Self, DatabaseError> {
        let backend = SharedMemoryBackend(Arc::new(RwLock::new(bytes)));
        let database = Builder::new().create_with_backend(backend.clone())?;

        Ok(Self { database, backend })
    }

    fn into_bytes(self) -> Result<Vec<u8>, DatabaseError> {
        drop(self.database);

        Ok(self.backend.into_bytes())
    }
}

pub struct ReadOnlyDatabase {
    database: RedbReadOnlyDatabase,
}

impl FromFile for ReadOnlyDatabase {
    fn open_from_file(path: &Path) -> Result<Self, DatabaseError> {
        let database = RedbReadOnlyDatabase::open(path)?;

        Ok(Self { database })
    }
}

pub(crate) trait ReadableSource {
    type Source: ReadableDatabase;

    fn source(&self) -> &Self::Source;
}

impl ReadableSource for MemoryDatabase {
    type Source = RedbDatabase;

    fn source(&self) -> &RedbDatabase {
        &self.database
    }
}

impl ReadableSource for ReadOnlyDatabase {
    type Source = RedbReadOnlyDatabase;

    fn source(&self) -> &RedbReadOnlyDatabase {
        &self.database
    }
}

pub(crate) trait ReadTransactionExt {
    fn open_table_or_none<K: Key + 'static, V: Value + 'static>(
        &self, definition: TableDefinition<K, V>,
    ) -> Result<Option<ReadOnlyTable<K, V>>, DatabaseError>;
}

impl ReadTransactionExt for ReadTransaction {
    fn open_table_or_none<K: Key + 'static, V: Value + 'static>(
        &self, definition: TableDefinition<K, V>,
    ) -> Result<Option<ReadOnlyTable<K, V>>, DatabaseError> {
        match self.open_table(definition) {
            Ok(table) => Ok(Some(table)),
            Err(TableError::TableDoesNotExist(_)) => Ok(None),
            Err(error) => Err(error.into()),
        }
    }
}

#[derive(Debug, Clone, Default)]
pub struct SharedMemoryBackend(Arc<RwLock<Vec<u8>>>);

impl SharedMemoryBackend {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn into_bytes(self) -> Vec<u8> {
        match Arc::try_unwrap(self.0) {
            Ok(lock) => lock.into_inner().unwrap_or_else(PoisonError::into_inner),
            Err(shared) => shared.read().unwrap_or_else(PoisonError::into_inner).clone(),
        }
    }
}

impl StorageBackend for SharedMemoryBackend {
    fn len(&self) -> Result<u64, IoError> {
        let buffer = self.0.read().unwrap_or_else(PoisonError::into_inner);

        Ok(buffer.len() as u64)
    }

    fn read(&self, offset: u64, out: &mut [u8]) -> Result<(), IoError> {
        let buffer = self.0.read().unwrap_or_else(PoisonError::into_inner);
        let offset = offset as usize;

        let Some(source) = buffer.get(offset..offset + out.len()) else {
            return Err(IoError::from(ErrorKind::UnexpectedEof));
        };

        out.copy_from_slice(source);
        Ok(())
    }

    fn set_len(&self, len: u64) -> Result<(), IoError> {
        let mut buffer = self.0.write().unwrap_or_else(PoisonError::into_inner);

        buffer.resize(len as usize, 0);
        Ok(())
    }

    fn sync_data(&self) -> Result<(), IoError> {
        Ok(())
    }

    fn write(&self, offset: u64, data: &[u8]) -> Result<(), IoError> {
        let mut buffer = self.0.write().unwrap_or_else(PoisonError::into_inner);
        let offset = offset as usize;

        let Some(destination) = buffer.get_mut(offset..offset + data.len()) else {
            return Err(IoError::from(ErrorKind::UnexpectedEof));
        };

        destination.copy_from_slice(data);
        Ok(())
    }
}
