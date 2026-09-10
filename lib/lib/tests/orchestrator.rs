// SPDX-FileCopyrightText: 2026 JustPav
// SPDX-FileCopyrightText: 2026 SmoothTeam
//
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

use std::any::TypeId;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};

use upac::errors::CommonError;
use upac::lock::LockError;
use upac::orchestrator::context::Context;
use upac::orchestrator::error::OrchestratorError;
use upac::orchestrator::stage::{NoRollback, RollbackGuard, Stage, StageResult};
use upac::orchestrator::{Orchestrator, SequentialOrchestrator};
use upac_abi::error::ErrorKind;
use upac_abi::hook::{CancelToken, ProgressEventBuilder};

#[derive(Debug, Clone, PartialEq, Eq)]
enum TestError {
    Common(CommonError),
    Stage(&'static str),
}

impl From<CommonError> for TestError {
    fn from(error: CommonError) -> Self {
        TestError::Common(error)
    }
}

struct TrackingGuard {
    label: &'static str,
    rolled_back: Arc<Mutex<Vec<&'static str>>>,
}

impl RollbackGuard for TrackingGuard {
    fn rollback(&mut self) -> Result<(), ErrorKind> {
        self.rolled_back.lock().unwrap().push(self.label);
        Ok(())
    }
}

struct RecordingStage {
    label: &'static str,
    ran: Arc<Mutex<Vec<&'static str>>>,
    rolled_back: Arc<Mutex<Vec<&'static str>>>,
}

impl Stage<TestError> for RecordingStage {
    fn run(
        &self, _context: &mut Context, _cancel: &CancelToken, progress: ProgressEventBuilder,
    ) -> Result<(ProgressEventBuilder, StageResult, Box<dyn RollbackGuard>), TestError> {
        self.ran.lock().unwrap().push(self.label);

        Ok((
            progress,
            StageResult::Advance,
            Box::new(TrackingGuard {
                label: self.label,
                rolled_back: Arc::clone(&self.rolled_back),
            }),
        ))
    }
}

struct FailingStage {
    label: &'static str,
}

impl Stage<TestError> for FailingStage {
    fn run(
        &self, _context: &mut Context, _cancel: &CancelToken, _progress: ProgressEventBuilder,
    ) -> Result<(ProgressEventBuilder, StageResult, Box<dyn RollbackGuard>), TestError> {
        Err(TestError::Stage(self.label))
    }
}

struct MarkerStage {
    ran: Arc<Mutex<Vec<&'static str>>>,
}

impl Stage<TestError> for MarkerStage {
    fn run(
        &self, _context: &mut Context, _cancel: &CancelToken, progress: ProgressEventBuilder,
    ) -> Result<(ProgressEventBuilder, StageResult, Box<dyn RollbackGuard>), TestError> {
        self.ran.lock().unwrap().push("a");
        Ok((progress, StageResult::Advance, Box::new(NoRollback)))
    }
}

struct RepeatBackToMarkerStage {
    attempts: AtomicUsize,
    ran: Arc<Mutex<Vec<&'static str>>>,
}

impl Stage<TestError> for RepeatBackToMarkerStage {
    fn run(
        &self, _context: &mut Context, _cancel: &CancelToken, progress: ProgressEventBuilder,
    ) -> Result<(ProgressEventBuilder, StageResult, Box<dyn RollbackGuard>), TestError> {
        self.ran.lock().unwrap().push("b");

        let result = if self.attempts.fetch_add(1, Ordering::SeqCst) == 0 {
            StageResult::RepeatBack(TypeId::of::<MarkerStage>())
        } else {
            StageResult::Advance
        };

        Ok((progress, result, Box::new(NoRollback)))
    }
}

struct ProvidesMarker;

struct ProvidesStage;

impl Stage<TestError> for ProvidesStage {
    fn provides(&self) -> Vec<TypeId> {
        vec![TypeId::of::<ProvidesMarker>()]
    }

    fn run(
        &self, _context: &mut Context, _cancel: &CancelToken, progress: ProgressEventBuilder,
    ) -> Result<(ProgressEventBuilder, StageResult, Box<dyn RollbackGuard>), TestError> {
        Ok((progress, StageResult::Advance, Box::new(NoRollback)))
    }
}

struct RequiresMarkerStage;

impl Stage<TestError> for RequiresMarkerStage {
    fn requires(&self) -> Vec<TypeId> {
        vec![TypeId::of::<ProvidesMarker>()]
    }

    fn run(
        &self, _context: &mut Context, _cancel: &CancelToken, progress: ProgressEventBuilder,
    ) -> Result<(ProgressEventBuilder, StageResult, Box<dyn RollbackGuard>), TestError> {
        Ok((progress, StageResult::Advance, Box::new(NoRollback)))
    }
}

#[test]
fn run_concurrent_runs_all_stages_in_declaration_order() {
    let ran = Arc::new(Mutex::new(Vec::new()));
    let rolled_back = Arc::new(Mutex::new(Vec::new()));

    let orchestrator: SequentialOrchestrator<TestError> = SequentialOrchestrator::new(vec![
        Box::new(RecordingStage {
            label: "a",
            ran: Arc::clone(&ran),
            rolled_back: Arc::clone(&rolled_back),
        }),
        Box::new(RecordingStage {
            label: "b",
            ran: Arc::clone(&ran),
            rolled_back: Arc::clone(&rolled_back),
        }),
    ]);
    let mut context = Context::new();
    let cancel = CancelToken::new();

    let result = orchestrator.run_concurrent(&mut context, &cancel);

    assert_eq!(result, Ok(()));
    assert_eq!(*ran.lock().unwrap(), vec!["a", "b"]);
}

#[test]
fn run_concurrent_stops_and_unwinds_previous_stages_in_reverse_order_on_failure() {
    let ran = Arc::new(Mutex::new(Vec::new()));
    let rolled_back = Arc::new(Mutex::new(Vec::new()));

    let orchestrator: SequentialOrchestrator<TestError> = SequentialOrchestrator::new(vec![
        Box::new(RecordingStage {
            label: "a",
            ran: Arc::clone(&ran),
            rolled_back: Arc::clone(&rolled_back),
        }),
        Box::new(RecordingStage {
            label: "b",
            ran: Arc::clone(&ran),
            rolled_back: Arc::clone(&rolled_back),
        }),
        Box::new(FailingStage { label: "c" }),
    ]);
    let mut context = Context::new();
    let cancel = CancelToken::new();

    let result = orchestrator.run_concurrent(&mut context, &cancel);

    assert_eq!(result, Err((2, TestError::Stage("c"))));
    assert_eq!(*ran.lock().unwrap(), vec!["a", "b"]);
    assert_eq!(*rolled_back.lock().unwrap(), vec!["b", "a"]);
}

#[test]
fn run_concurrent_returns_cancelled_error_when_cancel_requested_before_start() {
    let ran = Arc::new(Mutex::new(Vec::new()));
    let rolled_back = Arc::new(Mutex::new(Vec::new()));

    let orchestrator: SequentialOrchestrator<TestError> = SequentialOrchestrator::new(vec![Box::new(RecordingStage {
        label: "a",
        ran: Arc::clone(&ran),
        rolled_back: Arc::clone(&rolled_back),
    })]);
    let mut context = Context::new();
    let cancel = CancelToken::new();
    cancel.cancel();

    let result = orchestrator.run_concurrent(&mut context, &cancel);

    assert_eq!(result, Err((0, TestError::Common(CommonError::Cancelled))));
    assert!(ran.lock().unwrap().is_empty());
}

#[test]
fn run_concurrent_jumps_back_to_matching_stage_type_on_repeat_back() {
    let ran = Arc::new(Mutex::new(Vec::new()));

    let orchestrator: SequentialOrchestrator<TestError> = SequentialOrchestrator::new(vec![
        Box::new(MarkerStage { ran: Arc::clone(&ran) }),
        Box::new(RepeatBackToMarkerStage {
            attempts: AtomicUsize::new(0),
            ran: Arc::clone(&ran),
        }),
    ]);
    let mut context = Context::new();
    let cancel = CancelToken::new();

    let result = orchestrator.run_concurrent(&mut context, &cancel);

    assert_eq!(result, Ok(()));
    assert_eq!(*ran.lock().unwrap(), vec!["a", "b", "a", "b"]);
}

#[test]
fn validate_fails_when_required_dependency_is_never_provided() {
    let orchestrator: SequentialOrchestrator<TestError> =
        SequentialOrchestrator::new(vec![Box::new(RequiresMarkerStage)]);
    let context = Context::new();

    assert_eq!(orchestrator.validate(&context), Err(TypeId::of::<ProvidesMarker>()));
}

#[test]
fn validate_passes_when_earlier_stage_provides_the_dependency() {
    let orchestrator: SequentialOrchestrator<TestError> =
        SequentialOrchestrator::new(vec![Box::new(ProvidesStage), Box::new(RequiresMarkerStage)]);
    let context = Context::new();

    assert!(orchestrator.validate(&context).is_ok());
}

#[test]
fn validate_passes_when_context_already_holds_the_dependency() {
    let orchestrator: SequentialOrchestrator<TestError> =
        SequentialOrchestrator::new(vec![Box::new(RequiresMarkerStage)]);
    let mut context = Context::new();
    context.put(ProvidesMarker);

    assert!(orchestrator.validate(&context).is_ok());
}

#[test]
fn context_put_get_take_round_trip() {
    let mut context = Context::new();
    context.put(42u32);

    assert_eq!(context.get::<u32>(), Some(&42));
    assert_eq!(context.take::<u32>(), Some(42));
    assert_eq!(context.get::<u32>(), None);
}

#[test]
fn context_runtime_is_lazily_created_and_reused() {
    let mut context = Context::new();

    let first = context.runtime().unwrap();
    let second = context.runtime().unwrap();

    assert!(Arc::ptr_eq(&first, &second));
}

struct RepeatNTimesStage {
    repeat_count: usize,
    attempts: Arc<Mutex<usize>>,
}

impl Stage<TestError> for RepeatNTimesStage {
    fn run(
        &self, _context: &mut Context, _cancel: &CancelToken, progress: ProgressEventBuilder,
    ) -> Result<(ProgressEventBuilder, StageResult, Box<dyn RollbackGuard>), TestError> {
        let mut attempts = self.attempts.lock().unwrap();
        *attempts += 1;

        let result = if *attempts <= self.repeat_count {
            StageResult::Repeat
        } else {
            StageResult::Advance
        };

        Ok((progress, result, Box::new(NoRollback)))
    }
}

#[test]
fn run_concurrent_repeats_the_same_stage_until_it_advances() {
    let attempts = Arc::new(Mutex::new(0));

    let orchestrator: SequentialOrchestrator<TestError> =
        SequentialOrchestrator::new(vec![Box::new(RepeatNTimesStage {
            repeat_count: 3,
            attempts: Arc::clone(&attempts),
        })]);
    let mut context = Context::new();
    let cancel = CancelToken::new();

    let result = orchestrator.run_concurrent(&mut context, &cancel);

    assert_eq!(result, Ok(()));
    assert_eq!(*attempts.lock().unwrap(), 4);
}

struct NeverRunStage;

struct RepeatBackToUnreachedStage;

impl Stage<TestError> for RepeatBackToUnreachedStage {
    fn run(
        &self, _context: &mut Context, _cancel: &CancelToken, progress: ProgressEventBuilder,
    ) -> Result<(ProgressEventBuilder, StageResult, Box<dyn RollbackGuard>), TestError> {
        Ok((
            progress,
            StageResult::RepeatBack(TypeId::of::<NeverRunStage>()),
            Box::new(NoRollback),
        ))
    }
}

#[test]
fn run_concurrent_fails_with_stage_not_found_when_repeat_back_targets_an_unreached_stage() {
    let orchestrator: SequentialOrchestrator<TestError> =
        SequentialOrchestrator::new(vec![Box::new(RepeatBackToUnreachedStage)]);
    let mut context = Context::new();
    let cancel = CancelToken::new();

    let result = orchestrator.run_concurrent(&mut context, &cancel);

    assert_eq!(result, Err((0, TestError::Common(CommonError::StageNotFound))));
}

struct CancellingStage {
    cancel_token: Arc<CancelToken>,
    ran: Arc<Mutex<Vec<&'static str>>>,
}

impl Stage<TestError> for CancellingStage {
    fn run(
        &self, _context: &mut Context, _cancel: &CancelToken, progress: ProgressEventBuilder,
    ) -> Result<(ProgressEventBuilder, StageResult, Box<dyn RollbackGuard>), TestError> {
        self.ran.lock().unwrap().push("cancelling");
        self.cancel_token.cancel();

        Ok((progress, StageResult::Advance, Box::new(NoRollback)))
    }
}

#[test]
fn run_concurrent_returns_cancelled_error_when_cancelled_between_stages() {
    let ran = Arc::new(Mutex::new(Vec::new()));
    let cancel = Arc::new(CancelToken::new());

    let orchestrator: SequentialOrchestrator<TestError> = SequentialOrchestrator::new(vec![
        Box::new(CancellingStage {
            cancel_token: Arc::clone(&cancel),
            ran: Arc::clone(&ran),
        }),
        Box::new(RecordingStage {
            label: "never",
            ran: Arc::clone(&ran),
            rolled_back: Arc::new(Mutex::new(Vec::new())),
        }),
    ]);
    let mut context = Context::new();

    let result = orchestrator.run_concurrent(&mut context, &cancel);

    assert_eq!(result, Err((1, TestError::Common(CommonError::Cancelled))));
    assert_eq!(*ran.lock().unwrap(), vec!["cancelling"]);
}

#[test]
fn orchestrator_error_from_lock_error_is_the_setup_variant() {
    let error: OrchestratorError<TestError> = LockError::Busy.into();

    assert!(matches!(error, OrchestratorError::Setup(LockError::Busy)));
}

#[test]
fn orchestrator_error_from_stage_tuple_is_the_stage_variant() {
    let error: OrchestratorError<TestError> = (3usize, TestError::Stage("x")).into();

    assert!(matches!(error, OrchestratorError::Stage(3, TestError::Stage("x"))));
}
