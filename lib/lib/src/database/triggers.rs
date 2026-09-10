// SPDX-FileCopyrightText: 2026 JustPav
// SPDX-FileCopyrightText: 2026 SmoothTeam
//
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

use redb::{ReadableDatabase, TypeName, Value as RedbValue};

use uuid::Uuid;

use upac_types::codec::RedbCodable;
use upac_types::decoder::DeclarativeTrigger;

use super::error::DatabaseError;
use super::{MemoryDatabase, PACKAGES_TRIGGERS_TABLE, ReadTransactionExt, ReadableSource};

use crate::layout::database::PACKAGES_TRIGGERS_TYPE_NAME;

pub trait TriggerStore {
    fn get_declarative_triggers(&self, uuid: Uuid) -> Result<Option<DeclarativeTrigger>, DatabaseError>;
}

pub trait TriggerStoreMut: TriggerStore {
    fn set_declarative_triggers(&mut self, uuid: Uuid, trigger: &DeclarativeTrigger) -> Result<(), DatabaseError>;
    fn remove_declarative_triggers(&mut self, uuid: Uuid) -> Result<(), DatabaseError>;
}

impl<T: ReadableSource> TriggerStore for T {
    fn get_declarative_triggers(&self, uuid: Uuid) -> Result<Option<DeclarativeTrigger>, DatabaseError> {
        let transaction = self.source().begin_read()?;
        let Some(triggers) = transaction.open_table_or_none(PACKAGES_TRIGGERS_TABLE)? else {
            return Ok(None);
        };

        Ok(triggers.get(uuid)?.map(|guard| guard.value().0))
    }
}

impl TriggerStoreMut for MemoryDatabase {
    fn set_declarative_triggers(&mut self, uuid: Uuid, trigger: &DeclarativeTrigger) -> Result<(), DatabaseError> {
        let transaction = self.database.begin_write()?;

        transaction
            .open_table(PACKAGES_TRIGGERS_TABLE)?
            .insert(uuid, StoredTriggers::from_ref(trigger))?;

        transaction.commit()?;
        Ok(())
    }

    fn remove_declarative_triggers(&mut self, uuid: Uuid) -> Result<(), DatabaseError> {
        let transaction = self.database.begin_write()?;

        transaction.open_table(PACKAGES_TRIGGERS_TABLE)?.remove(uuid)?;

        transaction.commit()?;
        Ok(())
    }
}

#[derive(Debug)]
#[repr(transparent)]
pub(crate) struct StoredTriggers(pub(crate) DeclarativeTrigger);

impl StoredTriggers {
    fn from_ref(trigger: &DeclarativeTrigger) -> &StoredTriggers {
        // SAFETY: `StoredTriggers` is `#[repr(transparent)]` over `DeclarativeTrigger`, so the two
        // share identical layout and this reference cast is sound.
        unsafe { &*(trigger as *const DeclarativeTrigger as *const StoredTriggers) }
    }
}

impl RedbValue for StoredTriggers {
    type AsBytes<'a> = Vec<u8>;
    type SelfType<'a> = StoredTriggers;

    fn fixed_width() -> Option<usize> {
        None
    }

    fn from_bytes<'a>(data: &'a [u8]) -> StoredTriggers
    where
        Self: 'a,
    {
        let mut offset = 0;

        StoredTriggers(DeclarativeTrigger::redb_decode(data, &mut offset))
    }

    fn as_bytes<'a, 'b: 'a>(value: &'a StoredTriggers) -> Vec<u8>
    where
        Self: 'b,
    {
        let mut buf = Vec::new();

        value.0.redb_encode(&mut buf);
        buf
    }

    fn type_name() -> TypeName {
        TypeName::new(PACKAGES_TRIGGERS_TYPE_NAME)
    }
}
