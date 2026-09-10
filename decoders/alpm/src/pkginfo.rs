// SPDX-FileCopyrightText: 2026 JustPav
// SPDX-FileCopyrightText: 2026 SmoothTeam
//
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

use std::collections::HashMap;

use upac_abi::{CONSTRAINT_ANY, CONSTRAINT_EQUAL, CONSTRAINT_GREATER, CONSTRAINT_LESS};

use upac_types::decoder::parse_constraint_prefix;
use upac_types::error::DecodeError;
use upac_types::package::{DecodedPackageMeta, PackageDependency, PackageMeta, Version};
use upac_types::traits::DecodeMeta;

use super::alpm::{
    PKGINFO_ARCH_KEY, PKGINFO_DEPEND_KEY, PKGINFO_DESCRIPTION_KEY, PKGINFO_EPOCH_KEY, PKGINFO_LICENSE_KEY,
    PKGINFO_MAINTAINER_KEY, PKGINFO_NAME_KEY, PKGINFO_RELEASE_KEY, PKGINFO_SIZE_KEY, PKGINFO_URL_KEY,
    PKGINFO_VERSION_KEY,
};

macro_rules! required_field {
    ($fields:expr, $key:expr) => {
        $fields.remove($key).ok_or(DecodeError::MalformedMetadata)?
    };
}

macro_rules! numeric_field {
    ($fields:expr, $key:expr) => {
        $fields
            .get($key)
            .and_then(|value| value.parse().ok())
            .unwrap_or_default()
    };
}

const OPERATORS: [(&[u8], u8); 5] = [
    (b"<=", CONSTRAINT_LESS | CONSTRAINT_EQUAL),
    (b">=", CONSTRAINT_GREATER | CONSTRAINT_EQUAL),
    (b"<", CONSTRAINT_LESS),
    (b">", CONSTRAINT_GREATER),
    (b"=", CONSTRAINT_EQUAL),
];

pub struct PkgInfo<'a>(pub &'a str);

impl DecodeMeta for PkgInfo<'_> {
    fn decode(&self, sha256: [u8; 32]) -> Result<DecodedPackageMeta, DecodeError> {
        let (mut fields, dependencies) = self.parse_fields();

        let name = required_field!(fields, PKGINFO_NAME_KEY);
        let version = required_field!(fields, PKGINFO_VERSION_KEY);

        let raw_version = match fields.remove(PKGINFO_RELEASE_KEY) {
            Some(release) => format!("{version}-{release}"),
            None => version,
        };

        let epoch = numeric_field!(fields, PKGINFO_EPOCH_KEY);
        let installed_size = numeric_field!(fields, PKGINFO_SIZE_KEY);

        let meta = PackageMeta {
            name,
            version: Version {
                epoch,
                raw: raw_version,
            },
            arch: fields.remove(PKGINFO_ARCH_KEY).unwrap_or_else(|| "any".to_owned()),
            arch_sub: None,
            maintainer: fields.remove(PKGINFO_MAINTAINER_KEY).unwrap_or_default(),
            description: fields.remove(PKGINFO_DESCRIPTION_KEY).unwrap_or_default(),
            license: fields.remove(PKGINFO_LICENSE_KEY),
            url: fields.remove(PKGINFO_URL_KEY),
            sha256,
            installed_size,
        };

        Ok(DecodedPackageMeta { meta, dependencies })
    }
}

impl PkgInfo<'_> {
    fn parse_fields(&self) -> (HashMap<&str, String>, Vec<PackageDependency>) {
        let mut fields: HashMap<&str, String> = HashMap::new();
        let mut dependencies = Vec::new();

        for line in self.0.lines() {
            let line = line.trim();
            if line.is_empty() || line.starts_with('#') {
                continue;
            }

            let Some((key, value)) = line.split_once(" = ") else {
                continue;
            };

            if key == PKGINFO_DEPEND_KEY {
                dependencies.push(Self::parse_dependency(value));
            } else {
                fields.insert(key, value.to_owned());
            }
        }

        (fields, dependencies)
    }

    fn parse_dependency(value: &str) -> PackageDependency {
        let bytes = value.as_bytes();

        for index in 0..bytes.len() {
            let Some((constraint, operator_len)) = parse_constraint_prefix(&bytes[index..], &OPERATORS) else {
                continue;
            };

            return PackageDependency {
                name: value[..index].to_owned(),
                constraint,
                version: Version::parse(&value[index + operator_len..]),
            };
        }

        PackageDependency {
            name: value.to_owned(),
            constraint: CONSTRAINT_ANY,
            version: Version::default(),
        }
    }
}
