// SPDX-FileCopyrightText: 2026 JustPav
// SPDX-FileCopyrightText: 2026 SmoothTeam
//
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

use std::ffi::{CString, c_void};
use std::mem::size_of;
use std::ptr::null;

use upac_abi::HookMessageFn;
use upac_abi::hook::{CProgressEvent, HookAck};
use upac_abi::types::CSlice;

use crate::traits::MessageHook;

pub struct ProgressEventBuilder {
    stage: u32,
    phase: u32,
    subject: Option<CString>,
    current: u64,
    total: u64,
}

impl ProgressEventBuilder {
    pub fn new(stage: u32) -> Self {
        Self {
            stage,
            phase: 0,
            subject: None,
            current: 0,
            total: 0,
        }
    }

    pub fn stage(&self) -> u32 {
        self.stage
    }

    pub fn phase(mut self, phase: u32) -> Self {
        self.phase = phase;
        self
    }

    pub fn subject(mut self, subject: impl Into<String>) -> Self {
        self.subject = CString::new(subject.into()).ok();
        self
    }

    pub fn progress(mut self, current: u64, total: u64) -> Self {
        self.current = current;
        self.total = total;
        self
    }

    pub fn build(&self) -> CProgressEvent {
        let subject = match &self.subject {
            Some(subject) => CSlice {
                ptr: subject.as_ptr().cast(),
                len: subject.as_bytes().len(),
            },
            None => CSlice { ptr: null(), len: 0 },
        };

        CProgressEvent {
            struct_size: size_of::<CProgressEvent>(),
            stage: self.stage,
            phase: self.phase,
            subject,
            current: self.current,
            total: self.total,
        }
    }
}

pub struct Message {
    hook_message: Option<HookMessageFn>,
    hook_message_context: *mut c_void,
}

impl Message {
    pub fn new(hook_message: Option<HookMessageFn>, hook_message_context: *mut c_void) -> Self {
        Self {
            hook_message,
            hook_message_context,
        }
    }
}

impl MessageHook for Message {
    fn send(&self, event: &CProgressEvent) -> HookAck {
        let Some(hook_message) = self.hook_message else {
            return HookAck::Delivered;
        };

        unsafe { hook_message(event as *const CProgressEvent, self.hook_message_context) }
    }
}
