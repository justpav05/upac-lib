use anyhow::Result;

use colored::Colorize;

use crate::config::Config;

// ── Публичное API ─────────────────────────────────────────────────────────────
pub fn run(_config: Config) -> Result<()> {
    eprintln!(
        "{} manual commit is no longer supported",
        "✗".red().bold()
    );
    eprintln!(
        "  {}",
        "OStree snapshots are now created automatically during install/remove."
            .dimmed()
    );

    anyhow::bail!("the 'commit' command has been removed in this version");
}
