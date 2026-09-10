// SPDX-FileCopyrightText: 2026 JustPav
// SPDX-FileCopyrightText: 2026 SmoothTeam
//
// SPDX-License-Identifier: GPL-3.0-only

use std::fs::{read, read_to_string, write};
use std::path::PathBuf;

use anyhow::{Context, Result};

use clap::Args as ClapArgs;

use i18n_embed_fl::fl;

use upac_pki::generate::{Identity, PemIdentity, SigningIdentity};
use upac_pki::signature::HookSignature;

use crate::errors::LocalizedPkiError;
use crate::locale::LOADER;

#[cfg(test)]
#[path = "../../tests/inline/sign_hook.rs"]
mod tests;

#[derive(ClapArgs)]
pub struct Args {
    #[arg(long)]
    pub hook: PathBuf,
    #[arg(long)]
    pub key: PathBuf,
    #[arg(long)]
    pub cert: PathBuf,
    #[arg(long)]
    pub signature: PathBuf,
}

pub fn run(args: Args) -> Result<()> {
    let signing_pem = PemIdentity {
        key_pem: read_to_string(&args.key)
            .with_context(|| format!("{}: {}", fl!(LOADER, "err-read"), args.key.display()))?,

        certificate_pem: read_to_string(&args.cert)
            .with_context(|| format!("{}: {}", fl!(LOADER, "err-read"), args.cert.display()))?,
    };

    let signing = SigningIdentity::from_pem(&signing_pem).map_err(LocalizedPkiError)?;

    let hook_bytes =
        read(&args.hook).with_context(|| format!("{}: {}", fl!(LOADER, "err-read"), args.hook.display()))?;

    let signature = HookSignature::sign(&hook_bytes, &signing).map_err(LocalizedPkiError)?;

    let signature_bytes = signature.to_bytes().map_err(LocalizedPkiError)?;

    write(&args.signature, signature_bytes)
        .with_context(|| format!("{}: {}", fl!(LOADER, "err-write"), args.signature.display()))?;

    Ok(())
}
