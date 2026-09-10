// SPDX-FileCopyrightText: 2026 JustPav
// SPDX-FileCopyrightText: 2026 SmoothTeam
//
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

use libloading::Library;

use upac_abi::{BOOT_ABI_VERSION, BootPluginAbiVersionFn, ConfirmBootFn, InstallFn, SetOneShotFn};

use super::BootPlugin;
use super::error::BootPluginError;
use super::manifest::BootPluginManifests;

macro_rules! load_symbol {
    ($library:expr, $name:literal) => {
        unsafe { load_symbol(&$library, $name)? }
    };
}

unsafe fn load_symbol<T: Copy>(library: &Library, name: &str) -> Result<T, BootPluginError> {
    unsafe { library.get::<T>(name.as_bytes()) }
        .map(|symbol| *symbol)
        .map_err(|_| BootPluginError::Symbol)
}

impl BootPlugin {
    pub(super) fn load_plugin(library_name: &str) -> Result<Self, BootPluginError> {
        let library = unsafe { Library::new(library_name) }.map_err(|_| BootPluginError::Load)?;

        let booter_abi_version: BootPluginAbiVersionFn = load_symbol!(library, "boot_abi_version");
        let set_one_shot: SetOneShotFn = load_symbol!(library, "set_one_shot");
        let confirm_boot: ConfirmBootFn = load_symbol!(library, "confirm_boot");
        let install: InstallFn = load_symbol!(library, "install");

        let got_booter_abi_version = unsafe { booter_abi_version() };
        if got_booter_abi_version != BOOT_ABI_VERSION {
            return Err(BootPluginError::AbiMismatch {
                got: got_booter_abi_version,
                expected: BOOT_ABI_VERSION,
            });
        }

        Ok(BootPlugin {
            set_one_shot,
            confirm_boot,

            install,
            _library: Some(library),
        })
    }
}

pub(super) fn load_boot_plugin_dynamic(
    manifests: &BootPluginManifests, name: &str,
) -> Result<BootPlugin, BootPluginError> {
    let manifest = manifests
        .0
        .get(name)
        .ok_or_else(|| BootPluginError::UnknownName(name.to_owned()))?;

    BootPlugin::load_plugin(&manifest.library)
}
