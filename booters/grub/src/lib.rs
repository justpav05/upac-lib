// SPDX-FileCopyrightText: 2026 JustPav
// SPDX-FileCopyrightText: 2026 SmoothTeam
//
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

use upac_abi::BOOT_ABI_VERSION;
use upac_abi::error::ErrorKind;
use upac_abi::request::{
    CBootPluginConfirmSuccsesBootRequest, CBootPluginInstallRequest, CBootPluginSetOneShotRequest,
};

use upac_types::request::{BootPluginConfirmSuccsesBootRequest, BootPluginInstallRequest, BootPluginSetOneShotRequest};
use upac_types::traits::Booter;

use self::backend::Grub;
use self::error::GrubError;

mod backend;
mod error;

include!(concat!(env!("OUT_DIR"), "/layout.rs"));

macro_rules! write_error {
    ($err_out:expr, $error:expr) => {
        if !$err_out.is_null() {
            unsafe { *$err_out = $error.into() };
        }
    };
}

/// # Safety
/// Touches no pointers — `unsafe extern "C"` only to match `upac_abi::BootPluginAbiVersionFn`.
#[cfg_attr(feature = "cdylib", unsafe(no_mangle))]
pub unsafe extern "C" fn boot_abi_version() -> u32 {
    BOOT_ABI_VERSION
}

/// # Safety
/// `request`, if non-null, must point to a valid, initialized `CBootPluginSetOneShotRequest` for the
/// duration of the call. `err_out`, if non-null, must point to writable `ErrorKind` storage.
#[cfg_attr(feature = "cdylib", unsafe(no_mangle))]
pub unsafe extern "C" fn set_one_shot(request: *const CBootPluginSetOneShotRequest, err_out: *mut ErrorKind) -> i32 {
    if request.is_null() {
        write_error!(err_out, GrubError::InvalidRequest);

        return -1;
    }

    let result = BootPluginSetOneShotRequest::try_from(unsafe { &*request })
        .map_err(|_| GrubError::InvalidRequest)
        .and_then(|request| Grub::new().and_then(|mut grub| grub.set_one_shot(&request.entry_name)));

    match result {
        Ok(()) => 0,

        Err(error) => {
            write_error!(err_out, error);

            -1
        }
    }
}

/// # Safety
/// `request`, if non-null, must point to a valid, initialized `CBootPluginConfirmSuccsesBootRequest` for the
/// duration of the call. `err_out`, if non-null, must point to writable `ErrorKind` storage.
#[cfg_attr(feature = "cdylib", unsafe(no_mangle))]
pub unsafe extern "C" fn confirm_boot(
    request: *const CBootPluginConfirmSuccsesBootRequest, err_out: *mut ErrorKind,
) -> i32 {
    if request.is_null() {
        write_error!(err_out, GrubError::InvalidRequest);

        return -1;
    }

    let result = BootPluginConfirmSuccsesBootRequest::try_from(unsafe { &*request })
        .map_err(|_| GrubError::InvalidRequest)
        .and_then(|request| {
            Grub::new().and_then(|mut grub| grub.confirm_boot(&request.entry_name, &request.esp_mount_point))
        });

    match result {
        Ok(()) => 0,

        Err(error) => {
            write_error!(err_out, error);

            -1
        }
    }
}

/// # Safety
/// `request`, if non-null, must point to a valid, initialized `CBootPluginInstallRequest` for the
/// duration of the call. `err_out`, if non-null, must point to writable `ErrorKind` storage.
#[cfg_attr(feature = "cdylib", unsafe(no_mangle))]
pub unsafe extern "C" fn install(request: *const CBootPluginInstallRequest, err_out: *mut ErrorKind) -> i32 {
    if request.is_null() {
        write_error!(err_out, GrubError::InvalidRequest);

        return -1;
    }

    let result = BootPluginInstallRequest::try_from(unsafe { &*request })
        .map_err(|_| GrubError::InvalidRequest)
        .and_then(|request| {
            Grub::new().and_then(|mut grub| {
                grub.install(
                    &request.esp_mount_point,
                    request.esp_partition_number,
                    request.esp_starting_lba,
                    request.esp_ending_lba,
                    request.esp_unique_partition_guid,
                    &request.to_slot,
                    &request.from_slot,
                )
            })
        });

    match result {
        Ok(()) => 0,

        Err(error) => {
            write_error!(err_out, error);

            -1
        }
    }
}
