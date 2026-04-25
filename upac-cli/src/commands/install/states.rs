// ── Imports ─────────────────────────────────────────────────────────────────
use indicatif::{ProgressBar, ProgressStyle};

use sha2::{Digest, Sha256};

use std::env;
use std::fs;
use std::io::Read;
use std::sync::Arc;
use std::time::Duration;

use super::{
    c_void, on_install_progress, Colorize, InstallMachine, PreparedPackage, Result, State, UpacLib,
};

use crate::backends::Backend;
use crate::ffi::{CInstallRequest, CPackageEntry, CSlice};
use crate::types::BackendKind;

// ── States ─────────────────────────────────────────────────────────────────
pub fn state_preparing_package(machine: &mut InstallMachine) -> Result<()> {
    machine.enter(State::PreparingPackage);
    spinner(&machine.progress_bar, "Verifying and extracting package...");

    let files: Vec<String> = machine.files.clone();

    let progress_bar_ptr = &machine.progress_bar as *const ProgressBar as *mut c_void;

    for (index, file) in files.iter().enumerate() {
        machine.enter(State::DetectingBackend(file.clone()));

        let kind = if let Some(flag) = &machine.backend {
            BackendKind::from_flag(flag)?
        } else {
            BackendKind::detect(file).ok_or_else(|| {
                anyhow::anyhow!("Cannot detect backend for '{file}'. Use --backend to specify one")
            })?
        };

        let backend = machine
            .loaded_backends
            .entry(kind.clone())
            .or_insert_with(|| {
                Arc::new(
                    Backend::load(&kind)
                        .expect(format!("Failed to load backend lib for {}", kind).as_str()),
                )
            })
            .clone();

        machine
            .progress_bar
            .println(format!("{} backend: {}", "→".cyan(), kind));

        let tmp_string_path = env::temp_dir()
            .to_str()
            .ok_or_else(|| anyhow::anyhow!("invalid temp dir path"))?
            .to_owned();

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

        let (meta_handle, temp_path_c) = backend
            .meta_prepare(&abs_file_str, &tmp_string_path, &checksum, progress_bar_ptr)
            .map_err(|err| {
                machine.progress_bar.finish_and_clear();
                err
            })?;

        let prepared_packege = PreparedPackage {
            meta_handle,
            temp_path_c,
            checksum,
            backend,
        };

        machine.prepared_packages.push(prepared_packege);
    }

    state_installing(machine)
}

fn state_installing(machine: &mut InstallMachine) -> Result<()> {
    machine.enter(State::Installing);

    let progress_bar_ptr = &machine.progress_bar as *const ProgressBar as *mut c_void;

    let packages_c: Vec<CPackageEntry> = machine
        .prepared_packages
        .iter()
        .map(|prepared_package| prepared_package.as_c_entry())
        .collect();

    let install_request_c = CInstallRequest {
        struct_size: size_of::<CInstallRequest>(),

        packages: packages_c.as_ptr(),
        packages_count: packages_c.len(),

        repo_path: CSlice::from_str(&machine.config.paths.repo_path),
        root_path: CSlice::from_str(&machine.config.paths.root_path),
        db_path: CSlice::from_str(&machine.config.paths.database_path),

        branch: CSlice::from_str(&machine.config.ostree.branch),
        prefix_directory: CSlice::from_str(&machine.config.ostree.prefix_directory),

        on_progress: Some(on_install_progress),
        progress_ctx: progress_bar_ptr,

        max_retries: machine.config.step_retries,
    };

    UpacLib::check(
        unsafe { (machine.upac_lib.as_ref().install)(install_request_c) },
        "install",
    )?;

    state_done(machine)
}

fn state_done(machine: &mut InstallMachine) -> Result<()> {
    machine.enter(State::Done);
    machine.progress_bar.finish_and_clear();

    for package in &machine.prepared_packages {
        let backend = &package.backend;
        let name_slice_c = unsafe { (backend.backend_meta_get_name)(package.meta_handle) };
        let version_slice_c = unsafe { (backend.backend_meta_get_version)(package.meta_handle) };

        let name = unsafe { name_slice_c.as_str() }.to_owned();
        let version = unsafe { version_slice_c.as_str() }.to_owned();

        println!("Installed: {} {}", name, version);
    }

    machine.prepared_packages.clear();
    machine.loaded_backends.clear();

    (machine.upac_lib.as_ref().deinit);

    Ok(())
}

// ── Helpers ───────────────────────────────────────────────────────────────────
fn spinner(progress_bar: &ProgressBar, message: &str) -> () {
    progress_bar.set_style(
        ProgressStyle::default_spinner()
            .tick_strings(&["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"])
            .template("{spinner:.cyan} {msg}")
            .unwrap(),
    );
    progress_bar.set_message(message.to_owned());
    progress_bar.enable_steady_tick(Duration::from_millis(80));
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
