// SPDX-FileCopyrightText: 2026 JustPav
// SPDX-FileCopyrightText: 2026 SmoothTeam
//
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

use std::collections::VecDeque;
use std::path::PathBuf;

use composefs::tree::FileSystem;

use upac::composefs::repository::ObjectID;
use upac::database::MemoryDatabase;
use upac::plugin::decoder::unpack::PackageUnpacker;

use upac_types::{DeclarativeTrigger, PackageTemp};

use crate::data::{SetupExistingData, SetupWholeDiskData};

pub(crate) struct GenesisInput {
    pub source: String,
    pub empty_config: bool,
    pub pinned: bool,
    pub boot_plugin: Option<String>,
}

pub(crate) struct ResolvedSourceDir(pub PathBuf);

pub(crate) struct PendingPackagePaths(pub VecDeque<String>);

pub(crate) struct TotalPackages(pub u64);

pub(crate) struct UnpackerState(pub PackageUnpacker);

pub(crate) struct PendingPackages(pub VecDeque<(PackageTemp, DeclarativeTrigger)>);

pub(crate) struct PrefixTree(pub FileSystem<ObjectID>);

pub(crate) struct ConfigTree(pub FileSystem<ObjectID>);

pub(crate) struct GenesisDatabase(pub MemoryDatabase);

pub(crate) struct PrefixDigest(pub ObjectID);

pub(crate) struct ConfigDigest(pub ObjectID);

impl From<&SetupExistingData<'_>> for GenesisInput {
    fn from(data: &SetupExistingData<'_>) -> Self {
        GenesisInput {
            source: data.source.to_owned(),
            empty_config: data.empty_config,
            pinned: data.pinned,
            boot_plugin: data.boot_plugin.map(str::to_owned),
        }
    }
}

impl From<&SetupWholeDiskData<'_>> for GenesisInput {
    fn from(data: &SetupWholeDiskData<'_>) -> Self {
        GenesisInput {
            source: data.source.to_owned(),
            empty_config: data.empty_config,
            pinned: data.pinned,
            boot_plugin: data.boot_plugin.map(str::to_owned),
        }
    }
}
