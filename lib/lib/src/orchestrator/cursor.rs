// SPDX-FileCopyrightText: 2026 JustPav
// SPDX-FileCopyrightText: 2026 SmoothTeam
//
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

use std::any::TypeId;

use upac_abi::hook::CancelToken;

use crate::errors::CommonError;
use crate::orchestrator::context::Context;
use crate::orchestrator::stage::{Stage, StageResult};

pub struct Cursor<E> {
    stages: Vec<Box<dyn Stage<E>>>,
    index: usize,
}

impl<E: 'static> Cursor<E> {
    pub fn new(stages: Vec<Box<dyn Stage<E>>>) -> Self {
        Self { stages, index: 0 }
    }

    pub fn stages(&self) -> &[Box<dyn Stage<E>>] {
        &self.stages
    }

    fn find(&self, target: TypeId) -> Option<usize> {
        self.stages[..self.index]
            .iter()
            .rposition(|stage| (**stage).type_id() == target)
    }
}

impl<E: From<CommonError> + 'static> Cursor<E> {
    pub fn next(
        &mut self, context: &mut Context, cancel: &CancelToken, previous: Option<StageResult>,
    ) -> Result<Option<usize>, (usize, E)> {
        if let Some(result) = previous {
            self.advance(context, result)?;
        }

        if cancel.is_cancelled() {
            context.unwind();
            return Err((self.index, CommonError::Cancelled.into()));
        }

        Ok((self.index < self.stages.len()).then_some(self.index))
    }

    fn advance(&mut self, context: &mut Context, result: StageResult) -> Result<(), (usize, E)> {
        self.index = match result {
            StageResult::Advance => self.index + 1,
            StageResult::Repeat => self.index,
            StageResult::RepeatBack(target) => self.find(target).ok_or_else(|| {
                context.unwind();
                (self.index, CommonError::StageNotFound.into())
            })?,
        };

        Ok(())
    }
}
