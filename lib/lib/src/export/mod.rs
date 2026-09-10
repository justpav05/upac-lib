// SPDX-FileCopyrightText: 2026 JustPav
// SPDX-FileCopyrightText: 2026 SmoothTeam
//
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

use upac_abi::LIB_ABI_VERSION;
use upac_abi::error::{CError, ErrorKind};
use upac_abi::hook::CancelToken;

use upac_types::error::CommandState;

pub mod mutated;
pub mod unmutated;

/// # Safety
/// Touches no pointers — `unsafe extern "C"` only to match the ABI calling convention.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lib_abi_version() -> u32 {
    LIB_ABI_VERSION
}

/// # Safety
/// `token`, if non-null, must point to a valid, initialized `CancelToken` for the duration of the
/// call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cancel(token: *mut CancelToken) {
    if token.is_null() {
        return;
    }
    unsafe { (*token).cancel() };
}

pub(crate) unsafe fn write_error<S: CommandState>(err_out: *mut CError, state: S, error: ErrorKind) {
    if !err_out.is_null() {
        unsafe {
            *err_out = CError {
                domain: S::DOMAIN,
                state: state.as_u32(),
                error,
            };
        }
    }
}

pub(crate) fn write_abi_error<S: CommandState>(error: ErrorKind, err_out: *mut CError) -> i32 {
    unsafe { write_error(err_out, S::VALIDATION, error) };
    -1
}

macro_rules! try_convert_abi {
    ($expr:expr, $err_out:expr, $state:ty) => {
        match $expr {
            Ok(value) => value,
            Err(error) => return crate::export::write_abi_error::<$state>(error, $err_out),
        }
    };
}
pub(crate) use try_convert_abi;
