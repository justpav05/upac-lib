// SPDX-FileCopyrightText: 2026 JustPav
// SPDX-FileCopyrightText: 2026 SmoothTeam
//
// SPDX-License-Identifier: GPL-3.0-only

use upac_abi::error::{CError, ErrorDomain, ErrorKind};
use upac_abi::package::CPackageMeta;
use upac_abi::response::CListPackagesResponse;
use upac_abi::types::{COwned, CVec};

use crate::locale;
use crate::types::abi::{invoke, invoke_with_response};

#[test]
fn invoke_returns_ok_on_a_zero_code() {
    assert!(invoke(|_error| 0).is_ok());
}

#[test]
fn invoke_propagates_the_localized_error_on_a_nonzero_code() {
    locale::init_for_test();

    let result = invoke(|error| unsafe {
        *error = CError {
            domain: ErrorDomain::Install,
            state: 0,
            error: ErrorKind::NotFound,
        };
        1
    });

    assert_eq!(result.unwrap_err().to_string(), "File not found (Install: Pre-hooks)");
}

#[test]
fn invoke_with_response_returns_the_validated_response_on_a_zero_code() {
    let result = invoke_with_response(|response: *mut CListPackagesResponse, _error| {
        unsafe { *response = CListPackagesResponse::new(CVec::from_owned(Vec::<CPackageMeta>::new())) };
        0
    });

    assert!(result.is_ok());
}

#[test]
fn invoke_with_response_propagates_the_localized_error_on_a_nonzero_code() {
    locale::init_for_test();

    let result = invoke_with_response(|_response: *mut CListPackagesResponse, error| unsafe {
        *error = CError {
            domain: ErrorDomain::Install,
            state: 0,
            error: ErrorKind::NotFound,
        };
        1
    });

    assert_eq!(result.err().unwrap().to_string(), "File not found (Install: Pre-hooks)");
}

#[test]
fn invoke_with_response_rejects_an_unvalidated_response() {
    let result = invoke_with_response(|_response: *mut CListPackagesResponse, _error| 0);

    assert!(result.is_err());
}
