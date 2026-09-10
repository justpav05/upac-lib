// SPDX-FileCopyrightText: 2026 JustPav
// SPDX-FileCopyrightText: 2026 SmoothTeam
//
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

use upac_types::decoder::DecoderTrigger;

use super::alpm::{POST_INSTALL_FN, POST_REMOVE_FN, POST_UPGRADE_FN, PRE_INSTALL_FN, PRE_REMOVE_FN, PRE_UPGRADE_FN};

pub fn scan(content: &str) -> Vec<String> {
    DecoderTrigger::ALL
        .into_iter()
        .map(native_name)
        .filter(|name| declares_function(content, name))
        .map(str::to_owned)
        .collect()
}

fn native_name(trigger: DecoderTrigger) -> &'static str {
    match trigger {
        DecoderTrigger::PreInstall => PRE_INSTALL_FN,
        DecoderTrigger::PostInstall => POST_INSTALL_FN,
        DecoderTrigger::PreUpgrade => PRE_UPGRADE_FN,
        DecoderTrigger::PostUpgrade => POST_UPGRADE_FN,
        DecoderTrigger::PreRemove => PRE_REMOVE_FN,
        DecoderTrigger::PostRemove => POST_REMOVE_FN,
    }
}

fn declares_function(content: &str, name: &str) -> bool {
    content.lines().any(|line| {
        if line.starts_with(char::is_whitespace) {
            return false;
        }

        let Some(rest) = line.strip_prefix(name) else {
            return false;
        };

        rest.trim_start().starts_with('(')
    })
}
