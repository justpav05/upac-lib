// SPDX-FileCopyrightText: 2026 JustPav
// SPDX-FileCopyrightText: 2026 SmoothTeam
//
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

use upac_macro::{CFree, CNew, CValidate};

use crate::error::ErrorKind;
use crate::memory::free_cslice;
use crate::types::{CSlice, check_size};

#[repr(C)]
#[derive(CFree, CNew, CValidate)]
pub struct CVersion {
    pub struct_size: usize,

    pub epoch: u32,
    #[non_empty]
    pub raw: CSlice,
}

#[repr(C)]
#[derive(CFree, CNew, CValidate)]
pub struct CPackageMeta {
    pub struct_size: usize,
    pub name: CSlice,
    pub version: CVersion,
    pub arch: CSlice,

    #[optional]
    pub arch_sub: CSlice,
    pub maintainer: CSlice,
    pub description: CSlice,
    #[optional]
    pub license: CSlice,
    #[optional]
    pub url: CSlice,
    pub sha256: [u8; 32],
    pub installed_size: u64,
}

#[repr(C)]
#[derive(CNew, CValidate)]
pub struct CPackageInfo {
    pub struct_size: usize,
    pub name: CSlice,
    pub arch: CSlice,
    #[optional]
    pub arch_sub: CSlice,
}

#[repr(C)]
#[derive(CFree, CNew, CValidate)]
pub struct CPackageDependency {
    pub struct_size: usize,

    pub name: CSlice,
    pub constraint: u8,
    pub version: CVersion,
}
