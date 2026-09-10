// SPDX-FileCopyrightText: 2026 JustPav
// SPDX-FileCopyrightText: 2026 SmoothTeam
//
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

use std::any::{Any, TypeId};

use upac_abi::error::ErrorKind;
use upac_abi::hook::CancelToken;
use upac_types::hook::ProgressEventBuilder;

use crate::orchestrator::context::Context;

#[derive(Clone, Copy)]
pub enum StageResult {
    Advance,
    Repeat,
    RepeatBack(TypeId),
}

pub trait RollbackGuard: Send + 'static {
    fn rollback(&mut self) -> Result<(), ErrorKind>;
}

pub trait Stage<E>: Any {
    fn requires(&self) -> Vec<TypeId> {
        Vec::new()
    }

    fn provides(&self) -> Vec<TypeId> {
        Vec::new()
    }

    fn run(
        &self, context: &mut Context, cancel: &CancelToken, progress: ProgressEventBuilder,
    ) -> Result<(ProgressEventBuilder, StageResult, Box<dyn RollbackGuard>), E>;
}

pub trait ConcurrentStage<E>: Send + 'static {
    fn run(
        self: Box<Self>, progress: ProgressEventBuilder,
    ) -> Result<(ProgressEventBuilder, StageResult, Box<dyn RollbackGuard>), E>;
}

pub struct NoRollback;

impl RollbackGuard for NoRollback {
    fn rollback(&mut self) -> Result<(), ErrorKind> {
        Ok(())
    }
}
