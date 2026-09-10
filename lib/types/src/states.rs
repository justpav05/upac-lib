// SPDX-FileCopyrightText: 2026 JustPav
// SPDX-FileCopyrightText: 2026 SmoothTeam
//
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

use upac_abi::error::ErrorDomain;

use upac_macro::{FromStageIndex, StageKey};

use crate::error::CommandState;

macro_rules! impl_command_state {
    ($name:ident, $domain:ident) => {
        impl CommandState for $name {
            const DOMAIN: ErrorDomain = ErrorDomain::$domain;
            const VALIDATION: Self = $name::Setup;

            fn as_u32(self) -> u32 {
                self as u32
            }
        }
    };
}

#[repr(u8)]
#[derive(Debug, Clone, Copy, PartialEq, Eq, FromStageIndex, StageKey)]
pub enum InstallStateId {
    PreHooks = 0,
    Fetching = 1,
    Preparation = 2,
    OpenTransaction = 3,
    ImportPackage = 4,
    CommitTransaction = 5,
    Merge = 6,
    Checkout = 7,
    Swap = 8,
    PostHooks = 9,
    Done = 10,
    Setup = 11,
}

impl_command_state!(InstallStateId, Install);

#[repr(u8)]
#[derive(Debug, Clone, Copy, PartialEq, Eq, FromStageIndex, StageKey)]
pub enum UninstallStateId {
    PreHooks = 0,
    Preparation = 1,
    OpenTransaction = 2,
    RemovePackage = 3,
    CommitTransaction = 4,
    Merge = 5,
    Checkout = 6,
    Swap = 7,
    PostHooks = 8,
    Done = 9,
    Setup = 10,
}

impl_command_state!(UninstallStateId, Uninstall);

#[repr(u8)]
#[derive(Debug, Clone, Copy, PartialEq, Eq, FromStageIndex, StageKey)]
pub enum RollbackStateId {
    PreHooks = 0,
    Merge = 1,
    Checkout = 2,
    Swap = 3,
    PostHooks = 4,
    Done = 5,
    Setup = 6,
}

impl_command_state!(RollbackStateId, Rollback);

#[repr(u8)]
#[derive(Debug, Clone, Copy, PartialEq, Eq, FromStageIndex, StageKey)]
pub enum FilesStateId {
    PreHooks = 0,
    OpenTransaction = 1,
    ApplyFile = 2,
    CommitTransaction = 3,
    Checkout = 4,
    Swap = 5,
    PostHooks = 6,
    Done = 7,
    Setup = 8,
}

impl_command_state!(FilesStateId, Files);

#[repr(u8)]
#[derive(Debug, Clone, Copy, PartialEq, Eq, FromStageIndex, StageKey)]
pub enum GcStateId {
    Pruning = 0,
    CollectRoots = 1,
    Cleaning = 2,
    Done = 3,
    Setup = 4,
}

impl_command_state!(GcStateId, Gc);

#[repr(u8)]
#[derive(Debug, Clone, Copy, PartialEq, Eq, FromStageIndex, StageKey)]
pub enum PinStateId {
    SetPinned = 0,
    Done = 1,
    Setup = 2,
}

impl_command_state!(PinStateId, Pin);

#[repr(u8)]
#[derive(Debug, Clone, Copy, PartialEq, Eq, FromStageIndex, StageKey)]
pub enum MimeStateId {
    Preparing = 0,
    Rendering = 1,
    Writing = 2,
    Done = 3,
    Setup = 4,
}

impl_command_state!(MimeStateId, Mime);

#[repr(u8)]
#[derive(Debug, Clone, Copy, PartialEq, Eq, FromStageIndex, StageKey)]
pub enum ListPackagesStateId {
    Fetching = 0,
    Done = 1,
    Setup = 2,
}

impl_command_state!(ListPackagesStateId, ListPackages);

#[repr(u8)]
#[derive(Debug, Clone, Copy, PartialEq, Eq, FromStageIndex, StageKey)]
pub enum ListConfigStateId {
    Fetching = 0,
    Done = 1,
    Setup = 2,
}

impl_command_state!(ListConfigStateId, ListConfig);

#[repr(u8)]
#[derive(Debug, Clone, Copy, PartialEq, Eq, FromStageIndex, StageKey)]
pub enum ListPrefixStateId {
    Fetching = 0,
    Done = 1,
    Setup = 2,
}

impl_command_state!(ListPrefixStateId, ListPrefix);

#[repr(u8)]
#[derive(Debug, Clone, Copy, PartialEq, Eq, FromStageIndex, StageKey)]
pub enum ListHistoryStateId {
    Fetching = 0,
    Done = 1,
    Setup = 2,
}

impl_command_state!(ListHistoryStateId, ListHistory);

#[repr(u8)]
#[derive(Debug, Clone, Copy, PartialEq, Eq, FromStageIndex, StageKey)]
pub enum DiffPrefixStateId {
    Preparing = 0,
    Comparing = 1,
    Done = 2,
    Setup = 3,
}

impl_command_state!(DiffPrefixStateId, DiffPrefix);

#[repr(u8)]
#[derive(Debug, Clone, Copy, PartialEq, Eq, FromStageIndex, StageKey)]
pub enum DiffConfigStateId {
    Preparing = 0,
    Comparing = 1,
    Done = 2,
    Setup = 3,
}

impl_command_state!(DiffConfigStateId, DiffConfig);

#[repr(u8)]
#[derive(Debug, Clone, Copy, PartialEq, Eq, FromStageIndex, StageKey)]
pub enum DiffPackagesStateId {
    Preparing = 0,
    Comparing = 1,
    Done = 2,
    Setup = 3,
}

impl_command_state!(DiffPackagesStateId, DiffPackages);

#[repr(u8)]
#[derive(Debug, Clone, Copy, PartialEq, Eq, FromStageIndex, StageKey)]
pub enum DiffStateId {
    Preparing = 0,
    Comparing = 1,
    Done = 2,
    Setup = 3,
}

impl_command_state!(DiffStateId, Diff);

#[repr(u8)]
#[derive(Debug, Clone, Copy, PartialEq, Eq, FromStageIndex, StageKey)]
pub enum UpdateStateId {
    PreHooks = 0,
    Fetching = 1,
    Preparation = 2,
    OpenTransaction = 3,
    ImportPackage = 4,
    CommitTransaction = 5,
    Merge = 6,
    Checkout = 7,
    Swap = 8,
    PostHooks = 9,
    Done = 10,
    Setup = 11,
}

impl_command_state!(UpdateStateId, Update);

#[repr(u8)]
#[derive(Debug, Clone, Copy, PartialEq, Eq, FromStageIndex, StageKey)]
pub enum SearchMetaStateId {
    Searching = 0,
    Done = 1,
    Setup = 2,
}

impl_command_state!(SearchMetaStateId, SearchMeta);

#[repr(u8)]
#[derive(Debug, Clone, Copy, PartialEq, Eq, FromStageIndex, StageKey)]
pub enum SearchFilesStateId {
    Searching = 0,
    Done = 1,
    Setup = 2,
}

impl_command_state!(SearchFilesStateId, SearchFiles);

#[repr(u8)]
#[derive(Debug, Clone, Copy, PartialEq, Eq, FromStageIndex, StageKey)]
pub enum SearchInMetaStateId {
    Searching = 0,
    Done = 1,
    Setup = 2,
}

impl_command_state!(SearchInMetaStateId, SearchInMeta);

#[repr(u8)]
#[derive(Debug, Clone, Copy, PartialEq, Eq, FromStageIndex, StageKey)]
pub enum SearchInPackageFilesStateId {
    Searching = 0,
    Done = 1,
    Setup = 2,
}

impl_command_state!(SearchInPackageFilesStateId, SearchInPackageFiles);

#[repr(u8)]
#[derive(Debug, Clone, Copy, PartialEq, Eq, FromStageIndex, StageKey)]
pub enum CommitStateId {
    PreHooks = 0,
    Transaction = 1,
    PostHooks = 2,
    Done = 3,
    Setup = 4,
}

impl_command_state!(CommitStateId, Commit);
