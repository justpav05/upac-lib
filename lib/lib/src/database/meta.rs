// SPDX-FileCopyrightText: 2026 JustPav
// SPDX-FileCopyrightText: 2026 SmoothTeam
//
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

use redb::{ReadableDatabase, ReadableTable, TypeName, Value as RedbValue};

use twox_hash::xxhash3_64::Hasher as XxHasher;

use uuid::Uuid;

use upac_types::codec::{RedbCodable, write_len_prefixed, write_opt_str};
use upac_types::package::PackageMeta;

use super::error::DatabaseError;
use super::{MemoryDatabase, PACKAGES_HASH_TABLE, PACKAGES_UUID_TABLE, ReadTransactionExt, ReadableSource};

use crate::layout::database::PACKAGES_META_TYPE_NAME;

pub trait MetaStore {
    fn identity_hash(name: &str, arch: &str, arch_sub: Option<&str>) -> u64 {
        let mut buf = Vec::new();

        write_len_prefixed(&mut buf, name.as_bytes());
        write_len_prefixed(&mut buf, arch.as_bytes());
        write_opt_str(&mut buf, arch_sub);

        XxHasher::oneshot(&buf)
    }

    fn lookup_uuid(
        by_name: &impl ReadableTable<u64, Uuid>, name: &str, arch: &str, arch_sub: Option<&str>,
    ) -> Result<Option<Uuid>, DatabaseError> {
        Ok(by_name
            .get(Self::identity_hash(name, arch, arch_sub))?
            .map(|guard| guard.value()))
    }

    fn find_package_uuid(&self, name: &str, arch: &str, arch_sub: Option<&str>) -> Result<Option<Uuid>, DatabaseError>;
    fn get_package_meta(&self, uuid: Uuid) -> Result<Option<PackageMeta>, DatabaseError>;
    fn list_packages_metas(&self) -> Result<Vec<PackageMeta>, DatabaseError>;
}

pub trait MetaStoreMut: MetaStore {
    fn insert_package_meta(&mut self, meta: &PackageMeta) -> Result<Uuid, DatabaseError>;
    fn update_package_meta(&mut self, meta: &PackageMeta) -> Result<(), DatabaseError>;
    fn remove_package_meta(
        &mut self, name: &str, arch: &str, arch_sub: Option<&str>,
    ) -> Result<PackageMeta, DatabaseError>;
}

impl<T: ReadableSource> MetaStore for T {
    fn find_package_uuid(&self, name: &str, arch: &str, arch_sub: Option<&str>) -> Result<Option<Uuid>, DatabaseError> {
        let transaction = self.source().begin_read()?;
        let Some(by_name) = transaction.open_table_or_none(PACKAGES_HASH_TABLE)? else {
            return Ok(None);
        };

        Self::lookup_uuid(&by_name, name, arch, arch_sub)
    }

    fn get_package_meta(&self, uuid: Uuid) -> Result<Option<PackageMeta>, DatabaseError> {
        let transaction = self.source().begin_read()?;
        let Some(packages) = transaction.open_table_or_none(PACKAGES_UUID_TABLE)? else {
            return Ok(None);
        };

        Ok(packages.get(uuid)?.map(|guard| guard.value().0))
    }

    fn list_packages_metas(&self) -> Result<Vec<PackageMeta>, DatabaseError> {
        let transaction = self.source().begin_read()?;
        let Some(packages) = transaction.open_table_or_none(PACKAGES_UUID_TABLE)? else {
            return Ok(Vec::new());
        };
        let mut out = Vec::new();

        for entry in packages.iter()? {
            let (_uuid, meta) = entry?;
            out.push(meta.value().0);
        }

        Ok(out)
    }
}

impl MetaStoreMut for MemoryDatabase {
    fn insert_package_meta(&mut self, meta: &PackageMeta) -> Result<Uuid, DatabaseError> {
        let uuid = Uuid::new_v4();
        let transaction = self.database.begin_write()?;

        transaction
            .open_table(PACKAGES_UUID_TABLE)?
            .insert(uuid, StoredPackageMeta::from_ref(meta))?;

        let hash = Self::identity_hash(&meta.name, &meta.arch, meta.arch_sub.as_deref());
        transaction.open_table(PACKAGES_HASH_TABLE)?.insert(hash, uuid)?;

        transaction.commit()?;
        Ok(uuid)
    }

    fn update_package_meta(&mut self, meta: &PackageMeta) -> Result<(), DatabaseError> {
        let transaction = self.database.begin_write()?;

        let by_name = transaction.open_table(PACKAGES_HASH_TABLE)?;
        let uuid = Self::lookup_uuid(&by_name, &meta.name, &meta.arch, meta.arch_sub.as_deref())?
            .ok_or(DatabaseError::PackageNotFound)?;

        transaction
            .open_table(PACKAGES_UUID_TABLE)?
            .insert(uuid, StoredPackageMeta::from_ref(meta))?;

        drop(by_name);
        transaction.commit()?;
        Ok(())
    }

    fn remove_package_meta(
        &mut self, name: &str, arch: &str, arch_sub: Option<&str>,
    ) -> Result<PackageMeta, DatabaseError> {
        let transaction = self.database.begin_write()?;

        let mut by_name = transaction.open_table(PACKAGES_HASH_TABLE)?;
        let uuid = Self::lookup_uuid(&by_name, name, arch, arch_sub)?.ok_or(DatabaseError::PackageNotFound)?;

        by_name.remove(Self::identity_hash(name, arch, arch_sub))?;

        let mut packages = transaction.open_table(PACKAGES_UUID_TABLE)?;
        let removed = packages.remove(uuid)?.ok_or(DatabaseError::PackageNotFound)?.value().0;

        drop(by_name);
        drop(packages);
        transaction.commit()?;

        Ok(removed)
    }
}

// Wraps `PackageMeta` (defined in the external `upac-types` crate) so `redb::Value` can be
// implemented for it here without violating the orphan rule.
#[derive(Debug)]
#[repr(transparent)]
pub(crate) struct StoredPackageMeta(pub(crate) PackageMeta);

impl StoredPackageMeta {
    fn from_ref(meta: &PackageMeta) -> &StoredPackageMeta {
        // SAFETY: `StoredPackageMeta` is `#[repr(transparent)]` over `PackageMeta`, so the two share
        // identical layout and this reference cast is sound.
        unsafe { &*(meta as *const PackageMeta as *const StoredPackageMeta) }
    }
}

impl RedbValue for StoredPackageMeta {
    type AsBytes<'a> = Vec<u8>;
    type SelfType<'a> = StoredPackageMeta;

    fn fixed_width() -> Option<usize> {
        None
    }

    fn from_bytes<'a>(data: &'a [u8]) -> StoredPackageMeta
    where
        Self: 'a,
    {
        let mut offset = 0;

        StoredPackageMeta(PackageMeta::redb_decode(data, &mut offset))
    }

    fn as_bytes<'a, 'b: 'a>(value: &'a StoredPackageMeta) -> Vec<u8>
    where
        Self: 'b,
    {
        let mut buf = Vec::new();

        value.0.redb_encode(&mut buf);
        buf
    }

    fn type_name() -> TypeName {
        TypeName::new(PACKAGES_META_TYPE_NAME)
    }
}
