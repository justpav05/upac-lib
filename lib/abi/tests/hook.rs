// SPDX-FileCopyrightText: 2026 JustPav
// SPDX-FileCopyrightText: 2026 SmoothTeam
//
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

use upac_abi::hook::CancelToken;

#[test]
fn cancel_token_starts_not_cancelled() {
    let token = CancelToken::new();

    assert!(!token.is_cancelled());
}

#[test]
fn cancel_token_default_starts_not_cancelled() {
    let token = CancelToken::default();

    assert!(!token.is_cancelled());
}

#[test]
fn cancel_token_cancel_is_observed() {
    let token = CancelToken::new();

    token.cancel();

    assert!(token.is_cancelled());
}

#[test]
fn cancel_token_reset_clears_a_cancellation() {
    let token = CancelToken::new();
    token.cancel();

    token.reset();

    assert!(!token.is_cancelled());
}
