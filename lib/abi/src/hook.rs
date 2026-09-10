// SPDX-FileCopyrightText: 2026 JustPav
// SPDX-FileCopyrightText: 2026 SmoothTeam
//
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

use std::sync::atomic::{AtomicU8, Ordering};

use crate::types::CSlice;

#[repr(u8)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HookAck {
    Delivered = 0,
    Retry = 1,
}

#[repr(C)]
pub struct CProgressEvent {
    pub struct_size: usize,
    pub stage: u32,
    pub phase: u32,
    pub subject: CSlice,
    pub current: u64,
    pub total: u64,
}

#[repr(C)]
pub struct CancelToken {
    cancelled: AtomicU8,
}

unsafe impl Sync for CancelToken {}

impl CancelToken {
    pub const fn new() -> Self {
        Self {
            cancelled: AtomicU8::new(0),
        }
    }

    pub fn cancel(&self) {
        self.cancelled.store(1, Ordering::Release);
    }

    pub fn is_cancelled(&self) -> bool {
        self.cancelled.load(Ordering::Acquire) != 0
    }

    pub fn reset(&self) {
        self.cancelled.store(0, Ordering::Release);
    }
}

impl Default for CancelToken {
    fn default() -> Self {
        Self::new()
    }
}

#[repr(C)]
pub struct CHookPreInstall {
    pub packages_count: u32,
    pub required_space: u64,
    pub free_space: u64,
}
