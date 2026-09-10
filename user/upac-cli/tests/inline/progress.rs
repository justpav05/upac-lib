// SPDX-FileCopyrightText: 2026 JustPav
// SPDX-FileCopyrightText: 2026 SmoothTeam
//
// SPDX-License-Identifier: GPL-3.0-only

use std::ffi::CString;
use std::mem::size_of;

use upac_abi::error::ErrorDomain;
use upac_abi::hook::CProgressEvent;
use upac_abi::types::{CBorrowed, CSlice};

use crate::locale;
use crate::types::progress::ProgressState;

fn event(stage: u32, current: u64, total: u64, subject: CSlice) -> CProgressEvent {
    CProgressEvent {
        struct_size: size_of::<CProgressEvent>(),
        stage,
        phase: 0,
        subject,
        current,
        total,
    }
}

#[test]
fn apply_with_zero_total_stays_on_spinner() {
    locale::init_for_test();
    let mut state = ProgressState::new(ErrorDomain::Install);

    state.apply(&event(0, 0, 0, CSlice::from_slice(None)));

    assert!(!state.is_bar);
    assert_eq!(state.bar.message(), "Pre-hooks");
}

#[test]
fn apply_with_nonzero_total_switches_to_bar_and_sets_position() {
    locale::init_for_test();
    let mut state = ProgressState::new(ErrorDomain::Install);

    state.apply(&event(0, 3, 10, CSlice::from_slice(None)));

    assert!(state.is_bar);
    assert_eq!(state.bar.length(), Some(10));
    assert_eq!(state.bar.position(), 3);
}

#[test]
fn apply_includes_subject_in_message_when_present() {
    locale::init_for_test();
    let mut state = ProgressState::new(ErrorDomain::Install);
    let subject = CString::new("foo.txt").unwrap();

    state.apply(&event(0, 0, 0, CSlice::from_borrowed(subject.as_bytes())));

    assert_eq!(state.bar.message(), "Pre-hooks: foo.txt");
}
