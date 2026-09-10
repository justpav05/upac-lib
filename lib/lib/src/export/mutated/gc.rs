// SPDX-FileCopyrightText: 2026 JustPav
// SPDX-FileCopyrightText: 2026 SmoothTeam
//
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

use std::panic::{AssertUnwindSafe, catch_unwind};

use upac_abi::error::{CError, ErrorKind};
use upac_abi::request::CGcRequest;

use upac_types::states::GcStateId;

use crate::export::{try_convert_abi, write_error};
use crate::mutated::gc::{GcData, run};

/// # Safety
/// Any borrowed byte-slice fields inside `request_c` must remain valid for the duration of the
/// call. `err_out`, if non-null, must point to writable `CError` storage.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn gc(request_c: CGcRequest, err_out: *mut CError) -> i32 {
    let gc_data = try_convert_abi!(GcData::try_from(&request_c), err_out, GcStateId);

    let result = catch_unwind(AssertUnwindSafe(|| run(gc_data)));

    match result {
        Ok(Ok(())) => 0,

        Ok(Err((state, error))) => {
            unsafe { write_error(err_out, state, ErrorKind::from(error)) };
            -1
        }

        Err(_) => {
            unsafe { write_error(err_out, GcStateId::Setup, ErrorKind::Unexpected) };
            -1
        }
    }
}
