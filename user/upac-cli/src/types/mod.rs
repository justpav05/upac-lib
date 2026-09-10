// SPDX-FileCopyrightText: 2026 JustPav
// SPDX-FileCopyrightText: 2026 SmoothTeam
//
// SPDX-License-Identifier: GPL-3.0-only

use anyhow::Result;

use std::env::temp_dir;
use std::ffi::CString;
use std::sync::Arc;

use super::libcore::Lib;

pub mod abi;
pub mod errors;
pub mod progress;

pub struct CommandContext {
    pub lib: Arc<Lib>,
    pub tmp_path: CString,
}

impl CommandContext {
    pub fn new(lib: Arc<Lib>) -> Result<CommandContext> {
        let tmp_path = CString::new(temp_dir().to_string_lossy().as_ref())?;

        Ok(CommandContext { lib, tmp_path })
    }
}
