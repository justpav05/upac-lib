// SPDX-FileCopyrightText: 2026 JustPav
// SPDX-FileCopyrightText: 2026 SmoothTeam
//
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

use std::collections::HashMap;

use upac_abi::hook::CancelToken;
use upac_abi::{FileDiffKind, PackageDiffKind};

use upac_types::entry::{DiffFileEntryCommon, DiffPackageEntry, DiffPrefixFileEntry, DiffUntrackedFileEntry};
use upac_types::hook::ProgressEventBuilder;
use upac_types::package::{PackageMeta, Version};

use super::{DiffError, DiffSnapshot};

use crate::database::attribution::FileAttribute;
use crate::orchestrator::context::{Context, ctx_take};
use crate::orchestrator::stage::{NoRollback, RollbackGuard, Stage, StageResult};

type PackageIdentity = (String, String, Option<String>);

pub struct ComparingStage;

impl Stage<DiffError> for ComparingStage {
    fn run(
        &self, context: &mut Context, _cancel: &CancelToken, progress: ProgressEventBuilder,
    ) -> Result<(ProgressEventBuilder, StageResult, Box<dyn RollbackGuard>), DiffError> {
        let snapshot = ctx_take!(context, DiffSnapshot);

        let mut packages = Self::diff_packages(snapshot.from_packages, snapshot.to_packages);
        let mut unattached_files = Vec::new();

        for (path, kind, source) in snapshot.changed_files {
            let database = match kind {
                FileDiffKind::Removed => &snapshot.from_database,
                FileDiffKind::Added | FileDiffKind::Modified => &snapshot.to_database,
            };

            match database.attribute_file(&path)? {
                Some(attribution) => {
                    let identity = Self::identity(&attribution.package_meta);

                    let entry = packages.entry(identity).or_insert_with(|| DiffPackageEntry {
                        name: attribution.package_meta.name.clone(),
                        kind: PackageDiffKind::FilesChanged,
                        version: attribution.package_meta.version.clone(),
                        files: Vec::new(),
                    });

                    entry.files.push(DiffPrefixFileEntry {
                        common: DiffFileEntryCommon { path, kind },
                        source,
                        package_name: attribution.package_meta.name,
                        is_user: attribution.file_entry.is_user,
                    });
                }
                None => unattached_files.push(DiffUntrackedFileEntry {
                    common: DiffFileEntryCommon { path, kind },
                    source,
                }),
            }
        }

        context.put(packages.into_values().collect::<Vec<_>>());
        context.put(unattached_files);

        Ok((progress, StageResult::Advance, Box::new(NoRollback)))
    }
}

impl ComparingStage {
    fn identity(meta: &PackageMeta) -> PackageIdentity {
        (meta.name.clone(), meta.arch.clone(), meta.arch_sub.clone())
    }

    fn diff_packages(from: Vec<PackageMeta>, to: Vec<PackageMeta>) -> HashMap<PackageIdentity, DiffPackageEntry> {
        let from: HashMap<_, _> = from.into_iter().map(|meta| (Self::identity(&meta), meta)).collect();
        let mut to: HashMap<_, _> = to.into_iter().map(|meta| (Self::identity(&meta), meta)).collect();

        let mut packages = HashMap::new();

        for (identity, from_meta) in from {
            match to.remove(&identity) {
                Some(to_meta) if to_meta.sha256 != from_meta.sha256 => {
                    Self::insert(
                        &mut packages,
                        identity,
                        to_meta.name,
                        PackageDiffKind::Modified,
                        to_meta.version,
                    );
                }
                Some(_) => {}
                None => {
                    Self::insert(
                        &mut packages,
                        identity,
                        from_meta.name,
                        PackageDiffKind::Removed,
                        from_meta.version,
                    );
                }
            }
        }

        for (identity, to_meta) in to {
            Self::insert(
                &mut packages,
                identity,
                to_meta.name,
                PackageDiffKind::Added,
                to_meta.version,
            );
        }

        packages
    }

    fn insert(
        packages: &mut HashMap<PackageIdentity, DiffPackageEntry>, identity: PackageIdentity, name: String,
        kind: PackageDiffKind, version: Version,
    ) {
        packages.insert(
            identity,
            DiffPackageEntry {
                name,
                kind,
                version,
                files: Vec::new(),
            },
        );
    }
}
