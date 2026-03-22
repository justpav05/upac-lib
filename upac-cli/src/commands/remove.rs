use anyhow::Result;

use colored::Colorize;

use indicatif::{ProgressBar, ProgressStyle};

use std::time::Duration;

use crate::config::Config;

use crate::ffi::{CSlice, CSliceArray, UpacLib};

const MAX_RETRIES: u8 = 10;

// ── FSM ───────────────────────────────────────────────────────────────────────

#[derive(Debug, Clone, PartialEq)]
enum State {
    ReadingMeta,
    RemovingLinks,
    RemovingFiles,
    UnregisteringPackage,
    RollingBack,
    Done,
    Failed(String),
}

struct RemoveMachine {
    config: Config,
    name: String,
    retries: u8,

    // Заполняется в ReadingMeta
    files: Vec<String>,

    stack: Vec<State>,
}

impl RemoveMachine {
    fn new(config: Config, name: String) -> Self {
        Self {
            config,
            name,
            retries: 0,
            files: Vec::new(),
            stack: Vec::new(),
        }
    }

    fn enter(&mut self, state: State) {
        self.stack.push(state);
    }

    fn exhausted(&self) -> bool {
        self.retries >= MAX_RETRIES
    }
}

// ── Состояния ─────────────────────────────────────────────────────────────────
fn state_reading_meta(machine: &mut RemoveMachine) -> Result<()> {
    machine.enter(State::ReadingMeta);

    let lib = UpacLib::load()?;

    let db_path = CSlice::from_str(&machine.config.paths.database_path);
    let name = CSlice::from_str(&machine.name);

    // Читаем список файлов пакета из БД
    let mut c_files = crate::ffi::CPackageFiles {
        name: CSlice::empty(),
        paths: CSliceArray {
            ptr: std::ptr::null_mut(),
            len: 0,
        },
    };

    let code = unsafe { (lib.db_get_files)(db_path, name, &mut c_files) };
    UpacLib::check(code, "get files")?;

    // Копируем пути в Rust память
    let paths = unsafe { std::slice::from_raw_parts(c_files.paths.ptr, c_files.paths.len) };

    machine.files = paths
        .iter()
        .map(|s| unsafe { s.as_str().to_owned() })
        .collect();
    unsafe { (lib.files_free)(&mut c_files) };

    println!(
        "{} removing {} ({} files)",
        "→".cyan(),
        machine.name.bold(),
        machine.files.len()
    );

    state_removing_links(machine)
}

fn state_removing_links(machine: &mut RemoveMachine) -> Result<()> {
    machine.enter(State::RemovingLinks);

    let pb = spinner(&format!(
        "Removing links{}...",
        if machine.retries > 0 {
            format!(" (retry {}/{})", machine.retries, MAX_RETRIES)
        } else {
            String::new()
        }
    ));

    for file in &machine.files {
        // Строим путь в root_path
        // file уже абсолютный путь типа /usr/bin/foo
        let root_file = format!(
            "{}{}",
            machine.config.paths.root_path.trim_end_matches('/'),
            file
        );

        match std::fs::remove_file(&root_file) {
            Ok(_) => {}
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {} // пропускаем
            Err(e) => {
                pb.finish_and_clear();
                return state_rolling_back(
                    machine,
                    format!("failed to remove link {root_file}: {e}"),
                );
            }
        }
    }

    pb.finish_and_clear();
    state_removing_files(machine)
}

fn state_removing_files(machine: &mut RemoveMachine) -> Result<()> {
    machine.enter(State::RemovingFiles);

    let pb = spinner("Removing files from repo...");

    for file in &machine.files {
        let repo_file = format!(
            "{}{}",
            machine.config.paths.repo_path.trim_end_matches('/'),
            file
        );

        match std::fs::remove_file(&repo_file) {
            Ok(_) => {}
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {} // пропускаем
            Err(e) => {
                pb.finish_and_clear();
                return state_rolling_back(
                    machine,
                    format!("failed to remove file {repo_file}: {e}"),
                );
            }
        }
    }

    pb.finish_and_clear();
    state_unregistering_package(machine)
}

fn state_unregistering_package(machine: &mut RemoveMachine) -> Result<()> {
    machine.enter(State::UnregisteringPackage);

    let pb = spinner("Updating database...");

    let lib = UpacLib::load()?;
    let db = CSlice::from_str(&machine.config.paths.database_path);
    let name = CSlice::from_str(&machine.name);

    let code = unsafe { (lib.db_remove_package)(db, name) };

    pb.finish_and_clear();
    UpacLib::check(code, "unregister package")?;

    state_done(machine)
}

fn state_rolling_back(machine: &mut RemoveMachine, reason: String) -> Result<()> {
    machine.enter(State::RollingBack);

    let pb = spinner("Rolling back — restoring links...");

    // Восстанавливаем хардлинки из repo_path обратно в root_path
    for file in &machine.files {
        let repo_file = format!(
            "{}{}",
            machine.config.paths.repo_path.trim_end_matches('/'),
            file
        );
        let root_file = format!(
            "{}{}",
            machine.config.paths.root_path.trim_end_matches('/'),
            file
        );

        // Создаём промежуточные директории если нужно
        if let Some(parent) = std::path::Path::new(&root_file).parent() {
            std::fs::create_dir_all(parent).ok();
        }

        // Восстанавливаем хардлинк если файл в репо ещё есть
        if std::path::Path::new(&repo_file).exists() {
            std::fs::hard_link(&repo_file, &root_file).ok();
        }
    }

    pb.finish_and_clear();

    if machine.exhausted() {
        let msg = format!("remove failed after {} retries: {reason}", MAX_RETRIES);
        machine.enter(State::Failed(msg.clone()));
        anyhow::bail!("{msg}");
    }

    machine.retries += 1;
    if machine.config.verbose {
        eprintln!(
            "{} retry {}/{}: {reason}",
            "⚠".yellow().bold(),
            machine.retries,
            MAX_RETRIES
        );
    }

    // Retry — заново с удаления линков
    state_removing_links(machine)
}

fn state_done(machine: &mut RemoveMachine) -> Result<()> {
    machine.enter(State::Done);
    println!("{} removed {}", "✓".green().bold(), machine.name.bold());
    Ok(())
}

// ── Публичное API ─────────────────────────────────────────────────────────────
pub fn run(config: Config, package_name: String) -> Result<()> {
    let mut machine = RemoveMachine::new(config, package_name);

    state_reading_meta(&mut machine).map_err(|err| {
        if !matches!(machine.stack.last(), Some(State::Failed(_))) {
            machine.enter(State::Failed(err.to_string()));
        }
        if machine.config.verbose {
            eprintln!(
                "{} failed at state {:?}",
                "✗".red().bold(),
                machine.stack.last()
            );
        }
        err
    })
}

// ── Хелперы ───────────────────────────────────────────────────────────────────
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
