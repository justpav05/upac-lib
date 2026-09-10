// SPDX-FileCopyrightText: 2026 JustPav
// SPDX-FileCopyrightText: 2026 SmoothTeam
//
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

use std::fs::{read_link, write};
use std::path::{Path, PathBuf};

use tempfile::{Builder, TempDir};
use upac::errors::CommonError;
use upac::orchestrator::stage::{ConcurrentStage, StageResult};
use upac::scripts::error::HookError;
use upac::scripts::file::HookFile;
use upac::scripts::load::load_hooks;
use upac::scripts::pipeline::{Operation, PipelineTrigger, Timing};
use upac::scripts::primitive::Step;
use upac_abi::hook::ProgressEventBuilder;
use upac_pki::generate::{Identity, SigningIdentity, generate_root, generate_signing_cert};
use upac_pki::signature::HookSignature;

fn scratch_dir(name: &str) -> TempDir {
    Builder::new().prefix(name).tempdir().unwrap()
}

fn root_cert_file(dir: &Path, common_name: &str) -> (PathBuf, SigningIdentity) {
    let root = generate_root(common_name).unwrap();
    let signing = generate_signing_cert(&format!("{common_name} signer"), &root).unwrap();

    let cert_path = dir.join("root.der");
    write(&cert_path, root.to_bytes().unwrap().certificate_der).unwrap();

    (cert_path, signing)
}

fn write_signed_hook(dir: &Path, name: &str, hook_toml: &str, signing: &SigningIdentity) {
    write(dir.join(format!("{name}.hook")), hook_toml).unwrap();

    let signature = HookSignature::sign(hook_toml.as_bytes(), signing).unwrap();
    write(dir.join(format!("{name}.hook.sig")), signature.to_bytes().unwrap()).unwrap();
}

#[test]
fn hook_file_parse_succeeds_for_pipeline_trigger() {
    let hook_file = HookFile::parse("operation = \"install\"\ntiming = \"pre\"\n").unwrap();

    assert_eq!(
        hook_file.pipeline_trigger(),
        Some(PipelineTrigger::pre(Operation::Install))
    );
}

#[test]
fn hook_file_parse_succeeds_for_trigger_map() {
    let hook_file = HookFile::parse("[triggers]\ndeb = [\"postinst\"]\n").unwrap();

    assert_eq!(hook_file.pipeline_trigger(), None);
    assert_eq!(hook_file.triggers.get("deb").unwrap(), &vec!["postinst".to_owned()]);
}

#[test]
fn hook_file_parse_fails_when_only_operation_is_set() {
    let result = HookFile::parse("operation = \"install\"\n");

    assert_eq!(result.unwrap_err(), HookError::InvalidTrigger);
}

#[test]
fn hook_file_parse_fails_when_only_timing_is_set() {
    let result = HookFile::parse("timing = \"post\"\n");

    assert_eq!(result.unwrap_err(), HookError::InvalidTrigger);
}

#[test]
fn hook_file_parse_fails_when_no_trigger_at_all() {
    let result = HookFile::parse("priority = 1\n");

    assert_eq!(result.unwrap_err(), HookError::NoTrigger);
}

#[test]
fn hook_file_parse_fails_on_malformed_toml() {
    let result = HookFile::parse("not valid toml [[[");

    assert_eq!(result.unwrap_err(), HookError::Parse);
}

#[test]
fn pipeline_trigger_pre_and_post_set_correct_timing() {
    assert_eq!(
        PipelineTrigger::pre(Operation::Update),
        PipelineTrigger {
            operation: Operation::Update,
            timing: Timing::Pre,
        }
    );
    assert_eq!(
        PipelineTrigger::post(Operation::Update),
        PipelineTrigger {
            operation: Operation::Update,
            timing: Timing::Post,
        }
    );
}

#[test]
fn touch_file_step_creates_missing_file_and_rollback_removes_it() {
    let dir = scratch_dir("touch-missing");
    let path = dir.path().join("marker");

    let mut hook_file = HookFile::parse(&format!(
        "operation = \"install\"\ntiming = \"pre\"\n\n[[steps]]\ntype = \"touch_file\"\npath = {:?}\n",
        path
    ))
    .unwrap();
    let mut step = hook_file.steps.remove(0);

    step.execute().unwrap();
    assert!(path.exists());

    step.rollback().unwrap();
    assert!(!path.exists());
}

#[test]
fn touch_file_step_leaves_preexisting_file_after_rollback() {
    let dir = scratch_dir("touch-existing");
    let path = dir.path().join("marker");
    write(&path, b"already here").unwrap();

    let mut hook_file = HookFile::parse(&format!(
        "operation = \"install\"\ntiming = \"pre\"\n\n[[steps]]\ntype = \"touch_file\"\npath = {:?}\n",
        path
    ))
    .unwrap();
    let mut step = hook_file.steps.remove(0);

    step.execute().unwrap();
    step.rollback().unwrap();

    assert!(path.exists());
}

#[test]
fn move_file_step_execute_and_rollback_round_trip() {
    let dir = scratch_dir("move-round-trip");
    let from = dir.path().join("a");
    let to = dir.path().join("b");
    write(&from, b"content").unwrap();

    let mut hook_file = HookFile::parse(&format!(
        "operation = \"install\"\ntiming = \"pre\"\n\n[[steps]]\ntype = \"move_file\"\nfrom = {:?}\nto = {:?}\n",
        from, to
    ))
    .unwrap();
    let mut step = hook_file.steps.remove(0);

    step.execute().unwrap();
    assert!(!from.exists());
    assert!(to.exists());

    step.rollback().unwrap();
    assert!(from.exists());
    assert!(!to.exists());
}

#[test]
fn create_symlink_step_execute_and_rollback() {
    let dir = scratch_dir("symlink");
    let target = dir.path().join("target");
    let link = dir.path().join("link");
    write(&target, b"content").unwrap();

    let mut hook_file = HookFile::parse(&format!(
        "operation = \"install\"\ntiming = \"pre\"\n\n[[steps]]\ntype = \"create_symlink\"\ntarget = {:?}\nlink = {:?}\n",
        target, link
    ))
    .unwrap();
    let mut step = hook_file.steps.remove(0);

    step.execute().unwrap();
    assert_eq!(read_link(&link).unwrap(), target);

    step.rollback().unwrap();
    assert!(!link.exists());
}

#[test]
fn primitive_vec_rollback_guard_unwinds_in_reverse_order() {
    use upac::orchestrator::stage::RollbackGuard;

    let dir = scratch_dir("rollback-order");
    let a = dir.path().join("a");
    let b = dir.path().join("b");
    let c = dir.path().join("c");
    write(&a, b"content").unwrap();

    let mut hook_file = HookFile::parse(&format!(
        concat!(
            "operation = \"install\"\ntiming = \"pre\"\n\n",
            "[[steps]]\ntype = \"move_file\"\nfrom = {:?}\nto = {:?}\n\n",
            "[[steps]]\ntype = \"move_file\"\nfrom = {:?}\nto = {:?}\n",
        ),
        a, b, b, c
    ))
    .unwrap();

    let mut executed = Vec::new();
    for mut step in hook_file.steps.drain(..) {
        step.execute().unwrap();
        executed.push(step);
    }
    assert!(c.exists());

    executed.rollback().unwrap();

    assert!(a.exists());
    assert!(!b.exists());
    assert!(!c.exists());
}

#[test]
fn hook_file_run_executes_all_steps_and_returns_advance() {
    let dir = scratch_dir("run-advance");
    let a = dir.path().join("a");
    let b = dir.path().join("b");

    let hook_file = HookFile::parse(&format!(
        concat!(
            "operation = \"install\"\ntiming = \"pre\"\n\n",
            "[[steps]]\ntype = \"touch_file\"\npath = {:?}\n\n",
            "[[steps]]\ntype = \"touch_file\"\npath = {:?}\n",
        ),
        a, b
    ))
    .unwrap();

    let (_, result, _guard) =
        ConcurrentStage::<CommonError>::run(Box::new(hook_file), ProgressEventBuilder::new(0)).unwrap();

    assert!(matches!(result, StageResult::Advance));
    assert!(a.exists());
    assert!(b.exists());
}

#[test]
fn hook_file_run_rolls_back_and_errors_when_a_critical_step_fails() {
    let dir = scratch_dir("run-critical-failure");
    let touched = dir.path().join("touched");
    let missing_from = dir.path().join("does-not-exist");
    let move_to = dir.path().join("move-to");

    let hook_file = HookFile::parse(&format!(
        concat!(
            "operation = \"install\"\ntiming = \"pre\"\ncritical = true\n\n",
            "[[steps]]\ntype = \"touch_file\"\npath = {:?}\n\n",
            "[[steps]]\ntype = \"move_file\"\nfrom = {:?}\nto = {:?}\n",
        ),
        touched, missing_from, move_to
    ))
    .unwrap();

    let result = ConcurrentStage::<CommonError>::run(Box::new(hook_file), ProgressEventBuilder::new(0));

    assert!(result.is_err());
    assert!(!touched.exists(), "the already-executed step must be rolled back");
}

#[test]
fn hook_file_run_stops_early_without_error_when_a_non_critical_step_fails() {
    let dir = scratch_dir("run-non-critical-failure");
    let touched = dir.path().join("touched");
    let missing_from = dir.path().join("does-not-exist");
    let move_to = dir.path().join("move-to");

    let hook_file = HookFile::parse(&format!(
        concat!(
            "operation = \"install\"\ntiming = \"pre\"\ncritical = false\n\n",
            "[[steps]]\ntype = \"touch_file\"\npath = {:?}\n\n",
            "[[steps]]\ntype = \"move_file\"\nfrom = {:?}\nto = {:?}\n",
        ),
        touched, missing_from, move_to
    ))
    .unwrap();

    let (_, result, _guard) =
        ConcurrentStage::<CommonError>::run(Box::new(hook_file), ProgressEventBuilder::new(0)).unwrap();

    assert!(matches!(result, StageResult::Advance));
    assert!(
        touched.exists(),
        "a non-critical failure must not roll back prior steps"
    );
}

#[test]
fn load_hooks_returns_matching_hook_for_signed_valid_file() {
    let hooks_dir = scratch_dir("load-valid");
    let (cert_path, signing) = root_cert_file(hooks_dir.path(), "load-valid root");
    write_signed_hook(
        hooks_dir.path(),
        "install",
        "operation = \"install\"\ntiming = \"pre\"\n",
        &signing,
    );

    let hooks = load_hooks(
        hooks_dir.path().to_str().unwrap(),
        cert_path.to_str().unwrap(),
        "hook",
        "sig",
    )
    .unwrap();

    assert_eq!(hooks.len(), 1);
    assert_eq!(
        hooks[0].pipeline_trigger(),
        Some(PipelineTrigger::pre(Operation::Install))
    );
}

#[test]
fn load_hooks_skips_files_with_non_matching_extension() {
    let hooks_dir = scratch_dir("load-skip-extension");
    let (cert_path, signing) = root_cert_file(hooks_dir.path(), "load-skip root");
    write_signed_hook(
        hooks_dir.path(),
        "install",
        "operation = \"install\"\ntiming = \"pre\"\n",
        &signing,
    );
    write(hooks_dir.path().join("notes.txt"), b"not a hook").unwrap();

    let hooks = load_hooks(
        hooks_dir.path().to_str().unwrap(),
        cert_path.to_str().unwrap(),
        "hook",
        "sig",
    )
    .unwrap();

    assert_eq!(hooks.len(), 1);
}

#[test]
fn load_hooks_fails_when_signature_is_tampered() {
    let hooks_dir = scratch_dir("load-tampered");
    let (cert_path, signing) = root_cert_file(hooks_dir.path(), "load-tampered root");
    write_signed_hook(
        hooks_dir.path(),
        "install",
        "operation = \"install\"\ntiming = \"pre\"\n",
        &signing,
    );

    write(
        hooks_dir.path().join("install.hook"),
        "operation = \"install\"\ntiming = \"post\"\n",
    )
    .unwrap();

    let result = load_hooks(
        hooks_dir.path().to_str().unwrap(),
        cert_path.to_str().unwrap(),
        "hook",
        "sig",
    );

    assert_eq!(result.unwrap_err(), HookError::InvalidSignature);
}

#[test]
fn load_hooks_fails_when_root_cert_is_unrelated() {
    let hooks_dir = scratch_dir("load-unrelated-root");
    let (_, signing) = root_cert_file(hooks_dir.path(), "load-unrelated signing root");
    let (unrelated_cert_path, _) = root_cert_file(hooks_dir.path(), "load-unrelated other root");
    write_signed_hook(
        hooks_dir.path(),
        "install",
        "operation = \"install\"\ntiming = \"pre\"\n",
        &signing,
    );

    let result = load_hooks(
        hooks_dir.path().to_str().unwrap(),
        unrelated_cert_path.to_str().unwrap(),
        "hook",
        "sig",
    );

    assert_eq!(result.unwrap_err(), HookError::InvalidSignature);
}

#[test]
fn load_hooks_fails_when_hooks_dir_is_missing() {
    let hooks_dir = scratch_dir("load-missing-dir").path().join("does-not-exist");
    let cert_dir = scratch_dir("load-missing-dir-cert");
    let (cert_path, _) = root_cert_file(cert_dir.path(), "load-missing-dir root");

    let result = load_hooks(hooks_dir.to_str().unwrap(), cert_path.to_str().unwrap(), "hook", "sig");

    assert!(matches!(result.unwrap_err(), HookError::Io(_)));
}
