// SPDX-FileCopyrightText: 2026 JustPav
// SPDX-FileCopyrightText: 2026 SmoothTeam
//
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

use std::panic::{AssertUnwindSafe, catch_unwind};

use upac_abi::error::{CError, ErrorKind};
use upac_abi::request::CPinRequest;

use upac_types::states::PinStateId;

use crate::export::{try_convert_abi, write_error};
use crate::mutated::pin::{PinData, run};

/// # Safety
/// Any borrowed byte-slice fields inside `request_c` must remain valid for the duration of the
/// call. `err_out`, if non-null, must point to writable `CError` storage.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn pin_deploy(request_c: CPinRequest, err_out: *mut CError) -> i32 {
    let pin_data = try_convert_abi!(PinData::try_from(&request_c), err_out, PinStateId);

    let result = catch_unwind(AssertUnwindSafe(|| run(pin_data)));

    match result {
        Ok(Ok(())) => 0,

        Ok(Err((state, error))) => {
            unsafe { write_error(err_out, state, ErrorKind::from(error)) };
            -1
        }

        Err(_) => {
            unsafe { write_error(err_out, PinStateId::Setup, ErrorKind::Unexpected) };
            -1
        }
    }
}
