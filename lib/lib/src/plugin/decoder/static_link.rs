// SPDX-FileCopyrightText: 2026 JustPav
// SPDX-FileCopyrightText: 2026 SmoothTeam
//
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

use upac_abi::DecodeFn;

use super::DecoderPlugin;

#[cfg(feature = "builtin-alpm")]
use upac_decoders_alpm::{decode as alpm_decode, manifest as alpm_manifest};

#[cfg(feature = "builtin-deb")]
use upac_decoders_deb::{decode as deb_decode, manifest as deb_manifest};

#[cfg(feature = "builtin-rpm")]
use upac_decoders_rpm::{decode as rpm_decode, manifest as rpm_manifest};

#[cfg(feature = "builtin-xbps")]
use upac_decoders_xbps::{decode as xbps_decode, manifest as xbps_manifest};

impl DecoderPlugin {
    fn load_plugin_from_static(decode: DecodeFn) -> Self {
        DecoderPlugin {
            decode,

            #[cfg(feature = "dynamic-plugins")]
            _library: None,
        }
    }
}

#[allow(
    clippy::vec_init_then_push,
    reason = "each push is independently cfg-gated, vec![] can't express that"
)]
pub(super) fn static_decoders() -> Vec<(&'static str, &'static [&'static str], DecoderPlugin)> {
    #[allow(
        unused_mut,
        reason = "mut is only needed when at least one builtin-* decoder feature is enabled"
    )]
    let mut decoders = Vec::new();

    #[cfg(feature = "builtin-alpm")]
    decoders.push((
        alpm_manifest::FORMAT,
        alpm_manifest::EXTENSIONS,
        DecoderPlugin::load_plugin_from_static(alpm_decode),
    ));

    #[cfg(feature = "builtin-deb")]
    decoders.push((
        deb_manifest::FORMAT,
        deb_manifest::EXTENSIONS,
        DecoderPlugin::load_plugin_from_static(deb_decode),
    ));

    #[cfg(feature = "builtin-rpm")]
    decoders.push((
        rpm_manifest::FORMAT,
        rpm_manifest::EXTENSIONS,
        DecoderPlugin::load_plugin_from_static(rpm_decode),
    ));

    #[cfg(feature = "builtin-xbps")]
    decoders.push((
        xbps_manifest::FORMAT,
        xbps_manifest::EXTENSIONS,
        DecoderPlugin::load_plugin_from_static(xbps_decode),
    ));

    decoders
}
