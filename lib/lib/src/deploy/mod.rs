// SPDX-FileCopyrightText: 2026 JustPav
// SPDX-FileCopyrightText: 2026 SmoothTeam
//
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

use std::cmp::Reverse;
use std::collections::HashSet;
use std::fs::{create_dir_all, read_dir, remove_dir, remove_dir_all};
use std::path::{Path, PathBuf};

use composefs::repository::Repository;
use composefs::tree::FileSystem;

use nix::mount::{MsFlags, mount, umount};
use nix::sched::{CloneFlags, unshare};

use rsblkid::device::TagName;
use rsblkid::probe::Probe;
use rsblkid::utils::evaluation::find_canonical_device_name_from_path;

use rsmount::tables::MountInfo;

use upac_types::settings::RuntimeSettings;

use self::digest::current_prefix_digest;
use self::error::SysrootError;

use crate::composefs::error::RepoError;
use crate::composefs::repository::{self, ObjectID};
use crate::database::record::DeployRecord;
use crate::errors::CommonError;
use crate::layout::boot::{ESP_MOUNT_FALLBACK, ESP_MOUNT_PRIMARY};
use crate::layout::deployment::{DEPLOYS_DIR, NEXT_SEQ_PATH, REPO_DIR, ROOT_DIR, SYSROOT_DIR};

pub mod digest;
pub mod error;
pub mod retention;

#[cfg(test)]
#[path = "../../tests/inline/deploy.rs"]
mod tests;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DeployMode {
    ReadOnly,
    ReadWrite,
}

impl From<DeployMode> for MsFlags {
    fn from(mode: DeployMode) -> Self {
        match mode {
            DeployMode::ReadOnly => MsFlags::MS_RDONLY,
            DeployMode::ReadWrite => MsFlags::empty(),
        }
    }
}

pub struct Deploy {
    sysroot: PathBuf,
    deploy: PathBuf,
    repo: PathBuf,
}

impl Deploy {
    pub fn new(mode: DeployMode) -> Result<Self, SysrootError> {
        let device_path = Self::device_path()?;
        let filesystem_type = Self::filesystem_type(device_path.as_path())?;
        let sysroot = Self::sysroot_path()?;

        unshare(CloneFlags::CLONE_NEWNS)?;
        mount(
            None::<&str>,
            "/",
            None::<&str>,
            MsFlags::MS_REC | MsFlags::MS_PRIVATE,
            None::<&str>,
        )?;
        mount(
            Some(&device_path),
            &sysroot,
            Some(filesystem_type.as_str()),
            mode.into(),
            None::<&str>,
        )?;

        let deploy = sysroot.join(DEPLOYS_DIR);
        if !deploy.try_exists()? {
            return Err(SysrootError::DeploysDirNotFound);
        }

        let repo = sysroot.join(REPO_DIR);
        if !repo.try_exists()? {
            return Err(SysrootError::RepoDirNotFound);
        }

        Ok(Self { sysroot, deploy, repo })
    }

    pub fn deploy(&self, prefix_digest: &str) -> PathBuf {
        self.deploy.join(prefix_digest)
    }

    pub(crate) fn next_seq_path(&self) -> PathBuf {
        self.sysroot.join(NEXT_SEQ_PATH)
    }

    pub fn deploys(&self) -> Result<Vec<String>, SysrootError> {
        let mut digests = Vec::new();

        for entry in read_dir(&self.deploy)? {
            let entry = entry?;

            if !entry.file_type()?.is_dir() {
                continue;
            }

            if let Some(digest) = entry.file_name().to_str() {
                digests.push(digest.to_owned());
            }
        }

        Ok(digests)
    }

    pub fn prune_deploys(&self) -> Result<Vec<String>, CommonError> {
        let retention_depth = RuntimeSettings::load().gc.retention_depth as usize;

        let mut deploy_records = DeployRecord::read_all(self)?;
        deploy_records.sort_by_key(|record| Reverse(record.seq));

        let mut pinned_deploys: HashSet<&String> = HashSet::new();

        if let Ok(current_deploy_name) = current_prefix_digest()
            && let Some(index) = deploy_records
                .iter()
                .position(|record| record.prefix_digest == current_deploy_name)
        {
            pinned_deploys.insert(&deploy_records[index].prefix_digest);

            if let Some(previous) = deploy_records.get(index + 1) {
                pinned_deploys.insert(&previous.prefix_digest);
            }
        }

        for record in &deploy_records {
            if record.pinned {
                pinned_deploys.insert(&record.prefix_digest);
            }
        }

        for record in deploy_records.iter().take(retention_depth) {
            pinned_deploys.insert(&record.prefix_digest);
        }

        let mut removed_deploys_names = Vec::new();
        for record in &deploy_records {
            if pinned_deploys.contains(&record.prefix_digest) {
                continue;
            }

            remove_dir_all(self.deploy(&record.prefix_digest)).map_err(RepoError::from)?;
            removed_deploys_names.push(record.prefix_digest.clone());
        }

        Ok(removed_deploys_names)
    }

    pub fn repo(&self) -> &Path {
        &self.repo
    }

    pub fn open_repository(&self) -> Result<Repository<ObjectID>, RepoError> {
        repository::open(&self.repo)
    }

    pub fn open_tree(&self, name: &str) -> Result<FileSystem<ObjectID>, RepoError> {
        repository::open_tree(&self.open_repository()?, name)
    }

    fn sysroot_path() -> Result<PathBuf, SysrootError> {
        let sysroot = Path::new(ROOT_DIR).join(SYSROOT_DIR);
        create_dir_all(&sysroot)?;

        Ok(sysroot)
    }

    fn device_path() -> Result<PathBuf, SysrootError> {
        let mut table = MountInfo::new()?;
        table.import_mountinfo()?;

        let raw_device_path = table
            .find_target(ROOT_DIR)
            .and_then(|entry| entry.source_path())
            .ok_or(SysrootError::RootDeviceNotFound)?;

        find_canonical_device_name_from_path(raw_device_path).ok_or(SysrootError::CanonicalDeviceNotFound)
    }

    fn filesystem_type(device_path: &Path) -> Result<String, SysrootError> {
        let mut probe = Probe::builder()
            .scan_device(device_path)
            .scan_device_superblocks(true)
            .build()?;

        probe.find_device_properties();

        let tag = probe
            .lookup_device_property_value(TagName::Type)
            .ok_or(SysrootError::FilesystemTypeNotFound)?;

        Ok(tag.value().to_owned())
    }
}

impl Drop for Deploy {
    fn drop(&mut self) {
        let _ = umount(&self.sysroot);
        let _ = remove_dir(&self.sysroot);
    }
}

pub fn find_esp_mount() -> Result<PathBuf, SysrootError> {
    let mut mount_table = MountInfo::new()?;
    mount_table.import_mountinfo()?;

    for candidate_for_mount in [ESP_MOUNT_PRIMARY, ESP_MOUNT_FALLBACK] {
        if mount_table.find_target(candidate_for_mount).is_some() {
            return Ok(PathBuf::from(candidate_for_mount));
        }
    }

    Err(SysrootError::EspNotFound)
}

#[cfg(test)]
impl Deploy {
    pub(crate) fn for_testing(deploy_dir: PathBuf) -> Self {
        Deploy {
            sysroot: deploy_dir.clone(),
            deploy: deploy_dir,
            repo: PathBuf::new(),
        }
    }
}
