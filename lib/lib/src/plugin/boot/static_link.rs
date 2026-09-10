// SPDX-FileCopyrightText: 2026 JustPav
// SPDX-FileCopyrightText: 2026 SmoothTeam
//
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

use upac_abi::{ConfirmBootFn, InstallFn, SetOneShotFn};

use super::BootPlugin;
use super::error::BootPluginError;

#[cfg(feature = "builtin-grub")]
use upac_boot_grub::{confirm_boot as grub_confirm_boot, install as grub_install, set_one_shot as grub_set_one_shot};

#[cfg(feature = "builtin-systemd-boot")]
use upac_boot_systemd_boot::{
    confirm_boot as systemd_boot_confirm_boot, install as systemd_boot_install,
    set_one_shot as systemd_boot_set_one_shot,
};

#[cfg(feature = "builtin-uki")]
use upac_boot_uki::{confirm_boot as uki_confirm_boot, install as uki_install, set_one_shot as uki_set_one_shot};

#[cfg(feature = "builtin-refind")]
use upac_boot_refind::{
    confirm_boot as refind_confirm_boot, install as refind_install, set_one_shot as refind_set_one_shot,
};

impl BootPlugin {
    fn load_plugin_from_static(set_one_shot: SetOneShotFn, confirm_boot: ConfirmBootFn, install: InstallFn) -> Self {
        BootPlugin {
            set_one_shot,
            confirm_boot,
            install,

            #[cfg(feature = "dynamic-plugins")]
            _library: None,
        }
    }
}

pub(super) fn load_boot_plugin_static(name: &str) -> Result<BootPlugin, BootPluginError> {
    #[cfg(feature = "builtin-uki")]
    if name == "uki" {
        return Ok(BootPlugin::load_plugin_from_static(
            uki_set_one_shot,
            uki_confirm_boot,
            uki_install,
        ));
    }

    #[cfg(feature = "builtin-systemd-boot")]
    if name == "systemd-boot" {
        return Ok(BootPlugin::load_plugin_from_static(
            systemd_boot_set_one_shot,
            systemd_boot_confirm_boot,
            systemd_boot_install,
        ));
    }

    #[cfg(feature = "builtin-grub")]
    if name == "grub" {
        return Ok(BootPlugin::load_plugin_from_static(
            grub_set_one_shot,
            grub_confirm_boot,
            grub_install,
        ));
    }

    #[cfg(feature = "builtin-refind")]
    if name == "refind" {
        return Ok(BootPlugin::load_plugin_from_static(
            refind_set_one_shot,
            refind_confirm_boot,
            refind_install,
        ));
    }

    Err(BootPluginError::UnknownName(name.to_owned()))
}
