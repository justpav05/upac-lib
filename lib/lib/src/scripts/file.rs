// SPDX-FileCopyrightText: 2026 JustPav
// SPDX-FileCopyrightText: 2026 SmoothTeam
//
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

use std::collections::HashMap;

use serde::Deserialize;

use upac_types::hook::ProgressEventBuilder;

use crate::errors::CommonError;
use crate::orchestrator::stage::{ConcurrentStage, RollbackGuard, StageResult};
use crate::scripts::error::HookError;
use crate::scripts::pipeline::{Operation, PipelineTrigger, Timing};
use crate::scripts::primitive::{Primitive, Step};

#[derive(Debug, Clone, Deserialize)]
pub struct HookFile {
    #[serde(default)]
    pub priority: i32,
    #[serde(default)]
    pub critical: bool,
    pub operation: Option<Operation>,
    pub timing: Option<Timing>,
    #[serde(default)]
    pub triggers: HashMap<String, Vec<String>>,
    #[serde(default)]
    pub steps: Vec<Primitive>,
}

impl HookFile {
    pub fn parse(raw: &str) -> Result<Self, HookError> {
        let file: HookFile = toml::from_str(raw)?;

        match (file.operation, file.timing) {
            (Some(_), None) | (None, Some(_)) => return Err(HookError::InvalidTrigger),
            (None, None) if file.triggers.is_empty() => return Err(HookError::NoTrigger),
            _ => {}
        }

        Ok(file)
    }

    pub fn pipeline_trigger(&self) -> Option<PipelineTrigger> {
        match (self.operation, self.timing) {
            (Some(operation), Some(timing)) => Some(PipelineTrigger { operation, timing }),
            _ => None,
        }
    }
}

impl<E: From<CommonError>> ConcurrentStage<E> for HookFile {
    fn run(
        self: Box<Self>, progress: ProgressEventBuilder,
    ) -> Result<(ProgressEventBuilder, StageResult, Box<dyn RollbackGuard>), E> {
        let HookFile { critical, steps, .. } = *self;

        let mut executed: Vec<Primitive> = Vec::with_capacity(steps.len());

        for mut primitive in steps {
            match primitive.execute() {
                Ok(()) => executed.push(primitive),
                Err(error) => {
                    if critical {
                        let _ = executed.rollback();

                        return Err(CommonError::from(error).into());
                    }

                    break;
                }
            }
        }

        Ok((progress, StageResult::Advance, Box::new(executed)))
    }
}
