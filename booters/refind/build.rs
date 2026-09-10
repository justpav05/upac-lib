// SPDX-FileCopyrightText: 2026 JustPav
// SPDX-FileCopyrightText: 2026 SmoothTeam
//
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

use std::env::var;
use std::error::Error;
use std::fs::{read_to_string, write};
use std::path::Path;

use toml::{Value, from_str};

fn main() -> Result<(), Box<dyn Error>> {
    let manifest = var("CARGO_MANIFEST_DIR")?;
    let source = Path::new(&manifest).join("../booter.toml");

    println!("cargo:rerun-if-changed={}", source.display());

    let raw = read_to_string(&source)?;
    let config: Value = from_str(&raw)?;

    let mut generated = String::new();
    generated.push_str(&generate_section(&config, "boot")?);
    generated.push_str(&generate_section(&config, "refind")?);

    let out = Path::new(&var("OUT_DIR")?).join("layout.rs");
    write(out, generated)?;

    Ok(())
}

fn generate_section(config: &Value, section: &str) -> Result<String, Box<dyn Error>> {
    let entries = config
        .get(section)
        .and_then(Value::as_table)
        .ok_or_else(|| format!("booter.toml: [{section}] must be a table"))?;

    let mut generated = String::new();
    generated.push_str(&format!("pub mod {section} {{\n"));

    for (key, value) in entries {
        let value = value
            .as_str()
            .ok_or_else(|| format!("booter.toml: {section}.{key} must be a string"))?;

        generated.push_str(&format!("    pub const {}: &str = {value:?};\n", key.to_uppercase()));
    }

    generated.push_str("}\n");

    Ok(generated)
}
