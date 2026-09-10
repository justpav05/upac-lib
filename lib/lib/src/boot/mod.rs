// SPDX-FileCopyrightText: 2026 JustPav
// SPDX-FileCopyrightText: 2026 SmoothTeam
//
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

use std::ffi::OsStr;
use std::path::Path;

use composefs::generic_tree::Stat;
use composefs::repository::Repository;
use composefs::tree::{Directory, FileSystem, Inode};

use composefs_boot::bootloader::{BootEntry, get_boot_resources};
use composefs_boot::cmdline::ComposefsCmdline;
use composefs_boot::write_boot::write_boot_simple;

use self::error::BootError;

use crate::composefs::repository::ObjectID;
use crate::layout::boot::UPAC_UKI_TO_SLOT;

pub mod error;

pub fn write_boot_entry(
    repository: &Repository<ObjectID>, tree: &FileSystem<ObjectID>, digest: ObjectID, boot_partition: &Path,
    prefix_digest: &str,
) -> Result<String, BootError> {
    let rooted_tree = wrap_under_usr(tree);
    let mut entries = get_boot_resources(&rooted_tree, repository)?;

    if entries.len() > 1 {
        return Err(BootError::AmbiguousBootResource);
    }
    let entry = entries.pop().ok_or(BootError::NoBootResource)?;

    let entry_name = match &entry {
        BootEntry::Type1(_) | BootEntry::UsrLibModulesVmLinuz(_) => prefix_digest.to_owned(),
        BootEntry::Type2(_) => UPAC_UKI_TO_SLOT.to_owned(),
    };

    let karg = ComposefsCmdline::new_v2(digest, false);
    write_boot_simple(repository, entry, &karg, boot_partition, None, Some(&entry_name), &[])?;

    Ok(entry_name)
}

fn wrap_under_usr(tree: &FileSystem<ObjectID>) -> FileSystem<ObjectID> {
    let mut root = Directory::new(Stat::uninitialized());
    root.insert(OsStr::new("usr"), Inode::Directory(Box::new(tree.root.clone())));

    FileSystem {
        root,
        leaves: tree.leaves.clone(),
    }
}
