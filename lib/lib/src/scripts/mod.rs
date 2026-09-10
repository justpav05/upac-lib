// SPDX-FileCopyrightText: 2026 JustPav
// SPDX-FileCopyrightText: 2026 SmoothTeam
//
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

use std::collections::{HashMap, HashSet};
use std::fs::{read, read_dir};
use std::str::from_utf8;

use upac_abi::hook::CancelToken;

use upac_types::hook::ProgressEventBuilder;

use upac_types::decoder::DeclarativeTrigger;

use upac_pki::signature::{HookSignature, RootCertificate};

use crate::errors::CommonError;
use crate::layout::hooks::{HOOK_EXTENSION, HOOKS_DIR, ROOT_CERT_PATH, SIGNATURE_EXTENSION};
use crate::orchestrator::context::Context;
use crate::orchestrator::stage::{ConcurrentStage, RollbackGuard, Stage, StageResult};
use crate::orchestrator::{Orchestrator, ParallelOrchestrator};
use crate::plugin::decoder::triggers::build_trigger_table;
use crate::scripts::error::HookError;
use crate::scripts::file::HookFile;
use crate::scripts::pipeline::{PipelineTrigger, Timing};
use crate::scripts::primitive::Primitive;

pub mod error;
pub mod file;
pub mod pipeline;
pub mod primitive;

pub struct HookStage {
    pub trigger: PipelineTrigger,
}

impl<E: From<CommonError> + Send + 'static> Stage<E> for HookStage {
    fn run(
        &self, context: &mut Context, cancel: &CancelToken, progress: ProgressEventBuilder,
    ) -> Result<(ProgressEventBuilder, StageResult, Box<dyn RollbackGuard>), E> {
        let runtime = context.runtime().map_err(HookError::from).map_err(CommonError::from)?;

        let hooks =
            load_hooks(HOOKS_DIR, ROOT_CERT_PATH, HOOK_EXTENSION, SIGNATURE_EXTENSION).map_err(CommonError::from)?;

        let matched: Vec<Box<dyn ConcurrentStage<E>>> = if self.trigger.timing == Timing::Declarative {
            let packages = context
                .get::<Vec<DeclarativeTrigger>>()
                .ok_or(CommonError::MissingResult)?;

            let mut tables = HashMap::new();
            for package in packages {
                if !tables.contains_key(&package.format) {
                    let table = build_trigger_table(&hooks, &package.format).map_err(CommonError::from)?;
                    tables.insert(package.format.clone(), table);
                }
            }

            let mut matched_ids = HashSet::new();
            for package in packages {
                let table = &tables[&package.format];

                for trigger_name in &package.triggers {
                    if let Some(entry) = table.iter().find(|entry| &entry.name == trigger_name) {
                        matched_ids.insert(entry.hook_id);
                    }
                }
            }

            hooks
                .into_iter()
                .enumerate()
                .filter(|(index, _)| matched_ids.contains(&(*index as u16)))
                .map(|(_, hook_file)| Box::new(hook_file) as Box<dyn ConcurrentStage<E>>)
                .collect()
        } else {
            hooks
                .into_iter()
                .filter(|hook_file| hook_file.pipeline_trigger() == Some(self.trigger))
                .map(|hook_file| Box::new(hook_file) as Box<dyn ConcurrentStage<E>>)
                .collect()
        };

        ParallelOrchestrator::new(matched, runtime)
            .run_concurrent(context, cancel)
            .map_err(|(_, error)| error)?;

        Ok((progress, StageResult::Advance, Box::new(Vec::<Primitive>::new())))
    }
}

pub fn load_hooks(
    hooks_dir: &str, root_cert_path: &str, hook_extension: &str, signature_extension: &str,
) -> Result<Vec<HookFile>, HookError> {
    let root_bytes = read(root_cert_path)?;
    let root_certificate = RootCertificate::from_bytes(&root_bytes)?;

    let mut hooks = Vec::new();

    for entry in read_dir(hooks_dir)? {
        let path = entry?.path();

        if path.extension().and_then(|extension| extension.to_str()) != Some(hook_extension) {
            continue;
        }

        let mut signature_path = path.clone().into_os_string();
        signature_path.push(".");
        signature_path.push(signature_extension);

        let hook_bytes = read(&path)?;
        let signature_bytes = read(&signature_path)?;

        let signature = HookSignature::from_bytes(&signature_bytes)?;
        signature.verify(&hook_bytes, &root_certificate)?;

        let hook_text = from_utf8(&hook_bytes)?;
        let hook_file = HookFile::parse(hook_text)?;

        hooks.push(hook_file);
    }

    Ok(hooks)
}
