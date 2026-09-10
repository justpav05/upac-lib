// SPDX-FileCopyrightText: 2026 JustPav
// SPDX-FileCopyrightText: 2026 SmoothTeam
//
// SPDX-License-Identifier: GPL-3.0-only

use std::fs::write;
use std::path::PathBuf;

use anyhow::{Context, Result};

use clap::Args as ClapArgs;

use i18n_embed_fl::fl;

use upac_pki::generate::{Identity, generate_root};

use crate::errors::LocalizedPkiError;
use crate::locale::LOADER;

#[cfg(test)]
#[path = "../../tests/inline/generate_root.rs"]
mod tests;

#[derive(ClapArgs)]
pub struct Args {
    #[arg(long)]
    pub common_name: String,
    #[arg(long)]
    pub key_out: PathBuf,
    #[arg(long)]
    pub cert_out: PathBuf,
}

pub fn run(args: Args) -> Result<()> {
    let root = generate_root(&args.common_name).map_err(LocalizedPkiError)?;

    let pem = root.to_pem().map_err(LocalizedPkiError)?;

    write(&args.key_out, &pem.key_pem)
        .with_context(|| format!("{}: {}", fl!(LOADER, "err-write"), args.key_out.display()))?;

    write(&args.cert_out, &pem.certificate_pem)
        .with_context(|| format!("{}: {}", fl!(LOADER, "err-write"), args.cert_out.display()))?;

    Ok(())
}
