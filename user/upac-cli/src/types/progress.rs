// SPDX-FileCopyrightText: 2026 JustPav
// SPDX-FileCopyrightText: 2026 SmoothTeam
//
// SPDX-License-Identifier: GPL-3.0-only

use std::os::raw::c_void;
use std::time::Duration;

use indicatif::{ProgressBar, ProgressStyle};

use upac_abi::error::ErrorDomain;
use upac_abi::hook::{CProgressEvent, HookAck};

use upac_types::settings::{ProgressSettings, RuntimeSettings};

use crate::types::errors::StageName;

#[cfg(test)]
#[path = "../../tests/inline/progress.rs"]
mod tests;

/// # Safety
/// `ctx` must be a valid, live pointer to a `ProgressState` for the whole duration of the FFI
/// call that this hook is registered for (guaranteed by construction: callers keep their
/// `ProgressState` on the stack for exactly that call, calling `ctx_ptr()` only after it's in
/// its final resting place).
pub unsafe extern "C" fn on_progress(event: *const CProgressEvent, ctx: *mut c_void) -> HookAck {
    let state = unsafe { &mut *ctx.cast::<ProgressState>() };
    let event = unsafe { &*event };

    state.apply(event);

    HookAck::Delivered
}

pub struct ProgressState {
    pub(crate) bar: ProgressBar,
    pub(crate) is_bar: bool,

    domain: ErrorDomain,
    settings: ProgressSettings,
}

impl ProgressState {
    pub fn new(domain: ErrorDomain) -> Self {
        let settings = RuntimeSettings::load().progress;

        let bar = ProgressBar::new_spinner();
        bar.set_style(spinner_style(&settings.spinner_template));
        bar.enable_steady_tick(Duration::from_millis(settings.tick_interval_ms));

        ProgressState {
            bar,
            domain,
            is_bar: false,
            settings,
        }
    }

    pub fn ctx_ptr(&mut self) -> *mut c_void {
        std::ptr::from_mut(self).cast()
    }

    pub fn finish(&self) {
        self.bar.finish_and_clear();
    }

    pub(crate) fn apply(&mut self, event: &CProgressEvent) {
        let stage = StageName::new(self.domain, event.stage).to_string();
        let subject = <&str>::try_from(&event.subject).unwrap_or_default();

        if event.total > 0 {
            if !self.is_bar {
                self.bar.set_style(bar_style(&self.settings.bar_template));
                self.is_bar = true;
            }
            self.bar.set_length(event.total);
            self.bar.set_position(event.current);
        }

        let message = if subject.is_empty() {
            stage
        } else {
            format!("{stage}: {subject}")
        };
        self.bar.set_message(message);
    }
}

fn spinner_style(template: &str) -> ProgressStyle {
    ProgressStyle::with_template(template).unwrap_or_else(|_| ProgressStyle::default_spinner())
}

fn bar_style(template: &str) -> ProgressStyle {
    ProgressStyle::with_template(template).unwrap_or_else(|_| ProgressStyle::default_bar())
}
