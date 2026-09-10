// SPDX-FileCopyrightText: 2026 JustPav
// SPDX-FileCopyrightText: 2026 SmoothTeam
//
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

use std::panic::{AssertUnwindSafe, catch_unwind};

use upac_abi::error::{CError, ErrorKind};
use upac_abi::request::CDiffPackagesRequest;
use upac_abi::response::CDiffPackagesResponse;

use crate::export::{try_convert_abi, write_error};
use crate::unmutated::diff_packages::{DiffPackagesData, run};

use upac_types::states::DiffPackagesStateId;

/// # Safety
/// Any borrowed byte-slice fields inside `request_c` must remain valid for the duration of the
/// call. `response_out` and `err_out`, if non-null, must each point to writable storage of the
/// matching type.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn diff_packages(
    request_c: CDiffPackagesRequest, response_out: *mut CDiffPackagesResponse, err_out: *mut CError,
) -> i32 {
    let diff_packages_data = try_convert_abi!(DiffPackagesData::try_from(&request_c), err_out, DiffPackagesStateId);

    let result = catch_unwind(AssertUnwindSafe(|| run(diff_packages_data)));

    match result {
        Ok(Ok(response)) => {
            if !response_out.is_null() {
                unsafe { *response_out = response.into() };
            }
            0
        }

        Ok(Err((state, error))) => {
            unsafe { write_error(err_out, state, ErrorKind::from(error)) };
            -1
        }

        Err(_) => {
            unsafe { write_error(err_out, DiffPackagesStateId::Setup, ErrorKind::Unexpected) };
            -1
        }
    }
}
