// ── Imports ─────────────────────────────────────────────────────────────────
use indicatif::{ProgressBar, ProgressStyle};

use sha2::{Digest, Sha256};

use std::fs;
use std::io::Read;
use std::process;
use std::time::Duration;

use super::{Colorize, InstallMachine, PreparedPackage, Result, State, UpacLib, UpacLibGuard};

use crate::backends::{Backend, BackendKind};
use crate::ffi::{CInstallRequest, CPackageEntry, CSlice};

// ── States ─────────────────────────────────────────────────────────────────
pub fn state_preparing_package(machine: &mut InstallMachine) -> Result<()> {
    machine.enter(State::PreparingPackage);
    machine.upac_lib = Some(UpacLibGuard::load()?);

    let files: Vec<String> = machine.files.clone();

    for (index, file) in files.iter().enumerate() {
        let kind = if let Some(flag) = &machine.backend {
            BackendKind::from_flag(flag)?
        } else {
            BackendKind::detect(file).ok_or_else(|| {
                anyhow::anyhow!("cannot detect backend for '{file}'. Use --backend to specify one")
            })?
        };

        machine.enter(State::DetectingBackend(file.clone()));
        println!("{} backend: {:?}", "→".cyan(), kind);

        let progress_bar = spinner("Verifying and extracting package...");

        let tmp_string_path = format!("/tmp/upac_install_{}_{}", process::id(), index);
        fs::remove_dir_all(&tmp_string_path).ok();
        fs::create_dir_all(&tmp_string_path)?;
        machine.tmp_dirs.push(tmp_string_path.clone());

        let backend = Backend::load(&kind)?;

        let abs_file = fs::canonicalize(file)
            .map_err(|err| anyhow::anyhow!("cannot resolve path '{file}': {err}"))?;
        let abs_file_str = abs_file
            .to_str()
            .ok_or_else(|| anyhow::anyhow!("invalid path encoding"))?
            .to_owned();

        let checksum = if machine.checksums.is_empty() {
            compute_checksum(&abs_file_str)?
        } else {
            machine.checksums[index].clone()
        };

        let package_meta = backend
            .meta_prepare(&abs_file_str, &tmp_string_path, &checksum)
            .map_err(|err| {
                progress_bar.finish_and_clear();
                err
            })?;

        progress_bar.finish_and_clear();

        machine.prepared_packages.push(PreparedPackage {
            meta: package_meta,
            temp_path: tmp_string_path,
            checksum,
        });
    }

    state_installing(machine)
}

fn state_installing(machine: &mut InstallMachine) -> Result<()> {
    machine.enter(State::Installing);

    let progress_bar = spinner("Installing...");

    let c_entries: Vec<CPackageEntry> = machine
        .prepared_packages
        .iter()
        .map(|pkg| CPackageEntry {
            meta: pkg.meta.as_c(),
            temp_path: CSlice::from_str(&pkg.temp_path),
            checksum: CSlice::from_str(&pkg.checksum),
        })
        .collect();

    let c_install_request = CInstallRequest {
        packages: c_entries.as_ptr(),
        packages_len: c_entries.len(),

        repo_path: CSlice::from_str(&machine.config.paths.repo_path),
        root_path: CSlice::from_str(&machine.config.paths.root_path),
        db_path: CSlice::from_str(&machine.config.paths.database_path),
        branch: CSlice::from_str(&machine.config.ostree.branch),
        max_retries: machine.config.step_retries,
    };

    let return_code = unsafe { (machine.upac_lib.as_ref().unwrap().install)(c_install_request) };

    progress_bar.finish_and_clear();
    UpacLib::check(return_code, "install")?;

    state_done(machine)
}

fn state_done(machine: &mut InstallMachine) -> Result<()> {
    machine.enter(State::Done);

    for pkg in &machine.prepared_packages {
        println!(
            "{} installed {} {}",
            "✓".green().bold(),
            pkg.meta.name.bold(),
            pkg.meta.version.dimmed()
        );
    }

    Ok(())
}

// ── Helpers ───────────────────────────────────────────────────────────────────
fn spinner(message: &str) -> ProgressBar {
    let progress_bar = ProgressBar::new_spinner();
    progress_bar.set_style(
        ProgressStyle::default_spinner()
            .tick_strings(&["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"])
            .template("{spinner:.cyan} {msg}")
            .unwrap(),
    );
    progress_bar.set_message(message.to_owned());
    progress_bar.enable_steady_tick(Duration::from_millis(80));
    progress_bar
}

fn compute_checksum(file_path: &str) -> Result<String> {
    let mut file =
        fs::File::open(file_path).map_err(|err| anyhow::anyhow!("failed to open file: {err}"))?;

    let mut hasher = Sha256::new();
    let mut buffer = [0u8; 4096];

    loop {
        let bytes_read = file.read(&mut buffer)?;
        if bytes_read == 0 {
            break;
        }
        hasher.update(&buffer[..bytes_read]);
    }

    Ok(hex::encode(hasher.finalize()))
}
