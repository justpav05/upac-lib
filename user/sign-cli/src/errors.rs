// SPDX-FileCopyrightText: 2026 JustPav
// SPDX-FileCopyrightText: 2026 SmoothTeam
//
// SPDX-License-Identifier: GPL-3.0-only

use std::error::Error;
use std::fmt::{Display, Formatter};

use i18n_embed_fl::fl;

use upac_pki::error::PkiError;

use crate::locale::LOADER;

#[cfg(test)]
#[path = "../tests/inline/errors.rs"]
mod tests;

#[derive(Debug)]
pub struct LocalizedPkiError(pub PkiError);

impl Display for LocalizedPkiError {
    fn fmt(&self, formatter: &mut Formatter<'_>) -> std::fmt::Result {
        let message = match self.0 {
            PkiError::Malformed => fl!(LOADER, "err-malformed"),
            PkiError::InvalidSignature => fl!(LOADER, "err-invalid-signature"),
            PkiError::Generation => fl!(LOADER, "err-generation"),
        };
        formatter.write_str(&message)
    }
}

impl Error for LocalizedPkiError {}
