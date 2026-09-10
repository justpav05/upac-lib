// SPDX-FileCopyrightText: 2026 JustPav
// SPDX-FileCopyrightText: 2026 SmoothTeam
//
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

use std::panic::{AssertUnwindSafe, catch_unwind};

use upac_abi::error::{CError, ErrorKind};
use upac_abi::request::CSearchMetaRequest;
use upac_abi::response::CSearchMetaResponse;

use crate::export::{try_convert_abi, write_error};
use crate::unmutated::search_meta::{SearchMetaData, run};

use upac_types::states::SearchMetaStateId;

/// # Safety
/// Any borrowed byte-slice fields inside `request_c` must remain valid for the duration of the
/// call. `response_out` and `err_out`, if non-null, must each point to writable storage of the
/// matching type.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn search_meta(
    request_c: CSearchMetaRequest, response_out: *mut CSearchMetaResponse, err_out: *mut CError,
) -> i32 {
    let search_meta_data = try_convert_abi!(SearchMetaData::try_from(&request_c), err_out, SearchMetaStateId);

    let result = catch_unwind(AssertUnwindSafe(|| run(search_meta_data)));

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
            unsafe { write_error(err_out, SearchMetaStateId::Setup, ErrorKind::Unexpected) };
            -1
        }
    }
}
