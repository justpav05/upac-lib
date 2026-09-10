// SPDX-FileCopyrightText: 2026 JustPav
// SPDX-FileCopyrightText: 2026 SmoothTeam
//
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

use std::ffi::c_void;

use self::error::ErrorKind;
use self::hook::{CProgressEvent, HookAck};
use self::request::{
    CBootPluginConfirmSuccsesBootRequest, CBootPluginInstallRequest, CBootPluginSetOneShotRequest, CDecodeRequest,
};
use self::response::CDecodeResponse;

pub mod error;
pub mod hook;
pub mod memory;
pub mod package;
pub mod request;
pub mod response;
pub mod types;

pub const LIB_ABI_VERSION: u32 = 2;
pub const BOOT_ABI_VERSION: u32 = 2;
pub const DECODER_ABI_VERSION: u32 = 2;

pub const CONSTRAINT_LESS: u8 = 0b001;
pub const CONSTRAINT_EQUAL: u8 = 0b010;
pub const CONSTRAINT_GREATER: u8 = 0b100;
pub const CONSTRAINT_ANY: u8 = CONSTRAINT_LESS | CONSTRAINT_EQUAL | CONSTRAINT_GREATER;

pub type BootPluginAbiVersionFn = unsafe extern "C" fn() -> u32;

pub type DecodePluginAbiVersionFn = unsafe extern "C" fn() -> u32;

pub type HookMessageFn = unsafe extern "C" fn(event: *const CProgressEvent, ctx: *mut c_void) -> HookAck;

pub type SetOneShotFn =
    unsafe extern "C" fn(request: *const CBootPluginSetOneShotRequest, err_out: *mut ErrorKind) -> i32;

pub type ConfirmBootFn =
    unsafe extern "C" fn(request: *const CBootPluginConfirmSuccsesBootRequest, err_out: *mut ErrorKind) -> i32;

pub type InstallFn = unsafe extern "C" fn(request: *const CBootPluginInstallRequest, err_out: *mut ErrorKind) -> i32;

pub type DecodeFn = unsafe extern "C" fn(request: *const CDecodeRequest, response_out: *mut CDecodeResponse) -> i32;

pub type FreeDecodeResponseFn = unsafe extern "C" fn(response: *mut CDecodeResponse);

#[repr(u8)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FileDiffKind {
    Added = 0,
    Removed = 1,
    Modified = 2,
}

impl FileDiffKind {
    pub fn from_u8(version: u8) -> Result<FileDiffKind, ErrorKind> {
        match version {
            0 => Ok(FileDiffKind::Added),
            1 => Ok(FileDiffKind::Removed),
            2 => Ok(FileDiffKind::Modified),
            _ => Err(ErrorKind::InvalidEntry),
        }
    }
}

#[repr(u8)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PackageDiffKind {
    Added = 0,
    Removed = 1,
    Modified = 2,
    FilesChanged = 3,
}

impl PackageDiffKind {
    pub fn from_u8(version: u8) -> Result<PackageDiffKind, ErrorKind> {
        match version {
            0 => Ok(PackageDiffKind::Added),
            1 => Ok(PackageDiffKind::Removed),
            2 => Ok(PackageDiffKind::Modified),
            3 => Ok(PackageDiffKind::FilesChanged),
            _ => Err(ErrorKind::InvalidEntry),
        }
    }
}

#[repr(u8)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DiffFileSource {
    Prefix = 0,
    Config = 1,
}

impl DiffFileSource {
    pub fn from_u8(version: u8) -> Result<DiffFileSource, ErrorKind> {
        match version {
            0 => Ok(DiffFileSource::Prefix),
            1 => Ok(DiffFileSource::Config),
            _ => Err(ErrorKind::InvalidEntry),
        }
    }
}

#[repr(u8)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FsKind {
    Ext4 = 0,
    Btrfs = 1,
    Xfs = 2,
}

impl FsKind {
    pub fn from_u8(version: u8) -> Result<FsKind, ErrorKind> {
        match version {
            0 => Ok(FsKind::Ext4),
            1 => Ok(FsKind::Btrfs),
            2 => Ok(FsKind::Xfs),
            _ => Err(ErrorKind::InvalidEntry),
        }
    }
}

impl AsRef<str> for FsKind {
    fn as_ref(&self) -> &str {
        match self {
            FsKind::Ext4 => "ext4",
            FsKind::Btrfs => "btrfs",
            FsKind::Xfs => "xfs",
        }
    }
}
