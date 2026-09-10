// SPDX-FileCopyrightText: 2026 JustPav
// SPDX-FileCopyrightText: 2026 SmoothTeam
//
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

use std::mem::MaybeUninit;

use upac_abi::error::ErrorKind;
use upac_abi::request::{
    CBootPluginConfirmSuccsesBootRequest, CBootPluginInstallRequest, CBootPluginSetOneShotRequest,
};
use upac_abi::{ConfirmBootFn, InstallFn, SetOneShotFn};

use upac_types::request::{BootPluginConfirmSuccsesBootRequest, BootPluginInstallRequest, BootPluginSetOneShotRequest};

use self::error::BootPluginError;

#[cfg(all(feature = "dynamic-plugins", feature = "builtin-booters"))]
compile_error!("dynamic-plugins and builtin-booters are mutually exclusive");

#[cfg(feature = "dynamic-plugins")]
use libloading::Library;

#[cfg(feature = "dynamic-plugins")]
use self::manifest::BootPluginManifests;

pub mod error;

#[cfg(feature = "dynamic-plugins")]
pub mod manifest;

#[cfg(feature = "dynamic-plugins")]
mod dynamic_link;

#[cfg(feature = "builtin-booters")]
mod static_link;

pub struct BootPlugins {
    #[cfg(feature = "dynamic-plugins")]
    manifests: BootPluginManifests,
}

impl BootPlugins {
    pub fn new() -> Result<Self, BootPluginError> {
        Ok(BootPlugins {
            #[cfg(feature = "dynamic-plugins")]
            manifests: BootPluginManifests::new()?,
        })
    }

    pub fn load(&self, name: &str) -> Result<BootPlugin, BootPluginError> {
        #[cfg(feature = "dynamic-plugins")]
        return dynamic_link::load_boot_plugin_dynamic(&self.manifests, name);

        #[cfg(feature = "builtin-booters")]
        return static_link::load_boot_plugin_static(name);

        #[cfg(not(any(feature = "dynamic-plugins", feature = "builtin-booters")))]
        {
            let _ = name;
            Err(BootPluginError::NoClaimant)
        }
    }
}

pub struct BootPlugin {
    set_one_shot: SetOneShotFn,
    confirm_boot: ConfirmBootFn,
    install: InstallFn,

    #[cfg(feature = "dynamic-plugins")]
    _library: Option<Library>,
}

impl BootPlugin {
    pub fn set_one_shot(&self, request: BootPluginSetOneShotRequest) -> Result<(), BootPluginError> {
        let request: CBootPluginSetOneShotRequest = request.into();

        let mut error = MaybeUninit::<ErrorKind>::uninit();

        let response_code = unsafe { (self.set_one_shot)(&request, error.as_mut_ptr()) };
        if response_code != 0 {
            return Err(BootPluginError::Reported(unsafe { error.assume_init() }));
        }

        Ok(())
    }

    pub fn confirm_boot(&self, request: BootPluginConfirmSuccsesBootRequest) -> Result<(), BootPluginError> {
        let request: CBootPluginConfirmSuccsesBootRequest = request.into();

        let mut error = MaybeUninit::<ErrorKind>::uninit();

        let response_code = unsafe { (self.confirm_boot)(&request, error.as_mut_ptr()) };
        if response_code != 0 {
            return Err(BootPluginError::Reported(unsafe { error.assume_init() }));
        }

        Ok(())
    }

    pub fn install(&self, request: BootPluginInstallRequest) -> Result<(), BootPluginError> {
        let request: CBootPluginInstallRequest = request.into();

        let mut error = MaybeUninit::<ErrorKind>::uninit();

        let response_code = unsafe { (self.install)(&request, error.as_mut_ptr()) };
        if response_code != 0 {
            return Err(BootPluginError::Reported(unsafe { error.assume_init() }));
        }

        Ok(())
    }
}
