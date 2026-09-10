// SPDX-FileCopyrightText: 2026 JustPav
// SPDX-FileCopyrightText: 2026 SmoothTeam
//
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

use std::cmp::Ordering;
use std::mem::size_of;

use serde::{Deserialize, Deserializer};

use upac_abi::error::ErrorKind;
use upac_abi::package::{CPackageDependency, CPackageInfo, CPackageMeta, CVersion};
use upac_abi::types::{COwned, CSlice};

use upac_macro::{CTryToRust, RedbCodec, RustToC};

// ── Version ─────────────────────────────────────────────────────────────────
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
enum VersionToken<'a> {
    Alpha(&'a str),
    Numeric(u64),
}

#[derive(Debug, Clone, PartialEq, Eq, CTryToRust, RedbCodec, RustToC)]
pub struct Version {
    pub epoch: u32,
    pub raw: String,
}

impl Default for Version {
    fn default() -> Self {
        Version {
            epoch: 0,
            raw: "1.0.0".to_owned(),
        }
    }
}

impl Version {
    pub fn parse(raw: &str) -> Version {
        match raw.split_once(':') {
            Some((epoch, rest)) => Version {
                epoch: epoch.parse().unwrap_or(0),
                raw: rest.to_owned(),
            },
            None => Version {
                epoch: 0,
                raw: raw.to_owned(),
            },
        }
    }
}

impl<'de> Deserialize<'de> for Version {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        let raw = String::deserialize(deserializer)?;

        Ok(Version::parse(&raw))
    }
}

impl PartialOrd for Version {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        Some(self.cmp(other))
    }
}

impl Ord for Version {
    fn cmp(&self, other: &Self) -> Ordering {
        if self.epoch != other.epoch {
            return self.epoch.cmp(&other.epoch);
        }

        let self_tokens = self.tokenize();
        let other_tokens = other.tokenize();

        let mut self_iter = self_tokens.iter();
        let mut other_iter = other_tokens.iter();

        loop {
            match (self_iter.next(), other_iter.next()) {
                (Some(a), Some(b)) => match a.cmp(b) {
                    Ordering::Equal => continue,
                    ordering => return ordering,
                },
                (Some(VersionToken::Numeric(_)), None) => return Ordering::Greater,
                (Some(VersionToken::Alpha(_)), None) => return Ordering::Less,
                (None, Some(VersionToken::Numeric(_))) => return Ordering::Less,
                (None, Some(VersionToken::Alpha(_))) => return Ordering::Greater,
                (None, None) => return Ordering::Equal,
            }
        }
    }
}

impl Version {
    fn tokenize(&self) -> Vec<VersionToken<'_>> {
        let bytes = self.raw.as_bytes();
        let mut tokens = Vec::new();
        let mut index = 0;

        while index < bytes.len() {
            if !bytes[index].is_ascii_alphanumeric() {
                index += 1;
                continue;
            }

            let start = index;
            if bytes[index].is_ascii_digit() {
                while index < bytes.len() && bytes[index].is_ascii_digit() {
                    index += 1;
                }
                let value = self.raw[start..index].parse().unwrap_or(u64::MAX);
                tokens.push(VersionToken::Numeric(value));
            } else {
                while index < bytes.len() && bytes[index].is_ascii_alphabetic() {
                    index += 1;
                }
                tokens.push(VersionToken::Alpha(&self.raw[start..index]));
            }
        }

        tokens
    }
}

// ── Package ─────────────────────────────────────────────────────────────────
#[derive(Debug, Clone)]
pub struct PackageTemp {
    pub meta: PackageMeta,
    pub temp_package_path: String,
}

#[derive(Debug, Clone, Default, Deserialize, CTryToRust, RedbCodec, RustToC)]
#[serde(default)]
pub struct PackageMeta {
    pub name: String,
    pub version: Version,
    pub arch: String,
    pub arch_sub: Option<String>,
    pub maintainer: String,
    pub description: String,
    pub license: Option<String>,
    pub url: Option<String>,
    pub sha256: [u8; 32],
    pub installed_size: u64,
}

// ── PackageEntry ────────────────────────────────────────────────────────────
#[derive(Debug, Clone)]
pub struct PackageEntry {
    pub name: String,
    pub arch: String,
    pub arch_sub: Option<String>,
}

#[derive(Debug, Clone, CTryToRust, RustToC)]
pub struct PackageInfo {
    pub name: String,
    pub arch: String,
    pub arch_sub: Option<String>,
}

#[derive(Debug, Clone, CTryToRust, RustToC)]
pub struct PackageDependency {
    pub name: String,
    pub constraint: u8,
    pub version: Version,
}

#[derive(Debug)]
pub struct DecodedPackageMeta {
    pub meta: PackageMeta,
    pub dependencies: Vec<PackageDependency>,
}
