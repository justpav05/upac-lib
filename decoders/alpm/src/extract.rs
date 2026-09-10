// SPDX-FileCopyrightText: 2026 JustPav
// SPDX-FileCopyrightText: 2026 SmoothTeam
//
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

use std::fs::File;
use std::io::Read;

use flate2::read::GzDecoder;
use tar::Archive;
use xz2::read::XzDecoder;
use zstd::stream::read::Decoder as ZstdDecoder;

use upac_abi::hook::CancelToken;

use upac_types::decoder::read_to_string;
use upac_types::error::DecodeError;

use super::alpm::{BUILDINFO_ENTRY, CHANGELOG_ENTRY, INSTALL_ENTRY, MTREE_ENTRY, PKGINFO_ENTRY};

const JUNK_ENTRIES: [&str; 3] = [BUILDINFO_ENTRY, MTREE_ENTRY, CHANGELOG_ENTRY];

pub struct ExtractedMetadata {
    pub pkginfo: String,
    pub install: Option<String>,
}

impl ExtractedMetadata {
    pub fn extract(package_path: &str, output_dir: &str, cancel: &CancelToken) -> Result<Self, DecodeError> {
        let file = File::open(package_path)?;
        let reader = Self::open_reader(package_path, file)?;

        let mut archive = Archive::new(reader);

        let mut pkginfo = None;
        let mut install = None;

        for entry in archive.entries()? {
            if cancel.is_cancelled() {
                return Err(DecodeError::Cancelled);
            }

            let mut entry = entry?;
            let entry_path = entry.path()?.to_string_lossy().into_owned();

            if entry_path == PKGINFO_ENTRY {
                pkginfo = Some(read_to_string(&mut entry)?);
                continue;
            }

            if entry_path == INSTALL_ENTRY {
                install = Some(read_to_string(&mut entry)?);
                continue;
            }

            if JUNK_ENTRIES.contains(&entry_path.as_str()) {
                continue;
            }

            entry.unpack_in(output_dir)?;
        }

        pkginfo
            .map(|pkginfo| ExtractedMetadata { pkginfo, install })
            .ok_or(DecodeError::MissingMetadata)
    }

    fn open_reader(package_path: &str, file: File) -> Result<Box<dyn Read>, DecodeError> {
        let Some((_, compression)) = package_path.rsplit_once(".pkg.tar") else {
            return Err(DecodeError::UnsupportedFormat);
        };

        match compression {
            ".zst" => Ok(Box::new(ZstdDecoder::new(file)?)),
            ".xz" => Ok(Box::new(XzDecoder::new(file))),
            ".gz" => Ok(Box::new(GzDecoder::new(file))),
            "" => Ok(Box::new(file)),
            _ => Err(DecodeError::UnsupportedFormat),
        }
    }
}
