// SPDX-FileCopyrightText: 2026 JustPav
// SPDX-FileCopyrightText: 2026 SmoothTeam
//
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

use std::any::{Any, TypeId};
use std::collections::{HashMap, HashSet};
use std::io::Error as IoError;
use std::sync::Arc;

use tokio::runtime::Runtime;

use upac_abi::hook::HookAck;
use upac_types::hook::ProgressEventBuilder;
use upac_types::traits::MessageHook;

use crate::orchestrator::stage::RollbackGuard;

macro_rules! ctx_get {
    ($context:expr, $ty:ty) => {
        $context
            .get::<$ty>()
            .ok_or($crate::errors::CommonError::MissingResult)?
    };
}
pub(crate) use ctx_get;

macro_rules! ctx_take {
    ($context:expr, $ty:ty) => {
        $context
            .take::<$ty>()
            .ok_or($crate::errors::CommonError::MissingResult)?
    };
}
pub(crate) use ctx_take;

pub struct Context {
    slots: HashMap<TypeId, Box<dyn Any>>,
    pub(super) rollback: Vec<Box<dyn RollbackGuard>>,
}

impl Context {
    pub fn new() -> Self {
        Self {
            slots: HashMap::new(),
            rollback: Vec::new(),
        }
    }

    pub fn put<T: Any>(&mut self, value: T) {
        self.slots.insert(TypeId::of::<T>(), Box::new(value));
    }

    pub fn get<T: Any>(&self) -> Option<&T> {
        self.slots
            .get(&TypeId::of::<T>())
            .and_then(|slot| slot.downcast_ref::<T>())
    }

    pub fn take<T: Any>(&mut self) -> Option<T> {
        self.slots
            .remove(&TypeId::of::<T>())
            .and_then(|slot| slot.downcast::<T>().ok())
            .map(|boxed| *boxed)
    }

    pub fn runtime(&mut self) -> Result<Arc<Runtime>, IoError> {
        if let Some(runtime) = self.get::<Arc<Runtime>>() {
            return Ok(Arc::clone(runtime));
        }

        let runtime = Arc::new(Runtime::new()?);
        self.put(Arc::clone(&runtime));

        Ok(runtime)
    }

    pub fn send_progress(&self, progress: &ProgressEventBuilder) {
        if let Some(hook) = self.get::<Box<dyn MessageHook>>() {
            let event = progress.build();
            while hook.send(&event) == HookAck::Retry {}
        }
    }

    pub(super) fn type_ids(&self) -> HashSet<TypeId> {
        self.slots.keys().copied().collect()
    }

    pub(super) fn unwind(&mut self) {
        while let Some(mut guard) = self.rollback.pop() {
            let _ = guard.rollback();
        }
    }
}

impl Default for Context {
    fn default() -> Self {
        Self::new()
    }
}
