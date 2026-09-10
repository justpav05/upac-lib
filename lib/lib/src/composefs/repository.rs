// SPDX-FileCopyrightText: 2026 JustPav
// SPDX-FileCopyrightText: 2026 SmoothTeam
//
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

use std::fs::File;
use std::io::Read;
use std::path::Path;

use composefs::erofs::reader::erofs_to_filesystem;
use composefs::erofs::writer::{ValidatedFileSystem, mkfs_erofs};
use composefs::fsverity::{FsVerityHashValue, Sha256HashValue};
use composefs::repository::{GcResult, Repository, RepositoryConfig};
use composefs::tree::FileSystem;

use nix::fcntl::AT_FDCWD;

use super::error::RepoError;

pub type ObjectID = Sha256HashValue;

pub fn init(path: &Path) -> Result<(Repository<ObjectID>, bool), RepoError> {
    Ok(Repository::init_path(AT_FDCWD, path, RepositoryConfig::default())?)
}

pub fn init_insecure(path: &Path) -> Result<(Repository<ObjectID>, bool), RepoError> {
    Ok(Repository::init_path(
        AT_FDCWD,
        path,
        RepositoryConfig::default().set_insecure(),
    )?)
}

pub(crate) fn open(path: &Path) -> Result<Repository<ObjectID>, RepoError> {
    Ok(Repository::open_path(AT_FDCWD, path)?)
}

pub(crate) fn open_tree(repository: &Repository<ObjectID>, name: &str) -> Result<FileSystem<ObjectID>, RepoError> {
    let (image, _enable_verity) = repository.open_image(name)?;

    let mut data = Vec::new();
    File::from(image).read_to_end(&mut data)?;

    Ok(erofs_to_filesystem(&data)?)
}

pub fn commit_tree(repository: &Repository<ObjectID>, tree: FileSystem<ObjectID>) -> Result<ObjectID, RepoError> {
    let validated = ValidatedFileSystem::new(tree)?;
    let data = mkfs_erofs(&validated);

    Ok(repository.write_image(None, &data)?)
}

pub fn object_id_from_hex(hex: &str) -> Result<ObjectID, RepoError> {
    Ok(ObjectID::from_hex(hex.as_bytes())?)
}

pub fn gc(repository: &Repository<ObjectID>, additional_roots: &[&str]) -> Result<GcResult, RepoError> {
    Ok(repository.gc(additional_roots)?)
}
