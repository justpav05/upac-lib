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

fn state_reading_meta(m: &mut RemoveMachine) -> Result<()> {
    m.enter(State::ReadingMeta);

    let lib = UpacLib::load()?;

    let db_path = CSlice::from_str(&m.config.paths.db_path);
    let name = CSlice::from_str(&m.name);

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

    m.files = paths
        .iter()
        .map(|s| unsafe { s.as_str().to_owned() })
        .collect();
    unsafe { (lib.files_free)(&mut c_files) };

    println!(
        "{} removing {} ({} files)",
        "→".cyan(),
        m.name.bold(),
        m.files.len()
    );

    state_removing_links(m)
}

fn state_removing_links(m: &mut RemoveMachine) -> Result<()> {
    m.enter(State::RemovingLinks);

    let pb = spinner(&format!(
        "Removing links{}...",
        if m.retries > 0 {
            format!(" (retry {}/{})", m.retries, MAX_RETRIES)
        } else {
            String::new()
        }
    ));

    for file in &m.files {
        // Строим путь в root_path
        // file уже абсолютный путь типа /usr/bin/foo
        let root_file = format!("{}{}", m.config.paths.root_path.trim_end_matches('/'), file);

        match std::fs::remove_file(&root_file) {
            Ok(_) => {}
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {} // пропускаем
            Err(e) => {
                pb.finish_and_clear();
                return state_rolling_back(m, format!("failed to remove link {root_file}: {e}"));
            }
        }
    }

    pb.finish_and_clear();
    state_removing_files(m)
}

fn state_removing_files(m: &mut RemoveMachine) -> Result<()> {
    m.enter(State::RemovingFiles);

    let pb = spinner("Removing files from repo...");

    for file in &m.files {
        let repo_file = format!("{}{}", m.config.paths.repo_path.trim_end_matches('/'), file);

        match std::fs::remove_file(&repo_file) {
            Ok(_) => {}
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {} // пропускаем
            Err(e) => {
                pb.finish_and_clear();
                return state_rolling_back(m, format!("failed to remove file {repo_file}: {e}"));
            }
        }
    }

    pb.finish_and_clear();
    state_unregistering_package(m)
}

fn state_unregistering_package(m: &mut RemoveMachine) -> Result<()> {
    m.enter(State::UnregisteringPackage);

    let pb = spinner("Updating database...");

    let lib = UpacLib::load()?;
    let db = CSlice::from_str(&m.config.paths.db_path);
    let name = CSlice::from_str(&m.name);

    let code = unsafe { (lib.db_remove_package)(db, name) };

    pb.finish_and_clear();
    UpacLib::check(code, "unregister package")?;

    state_done(m)
}

fn state_rolling_back(m: &mut RemoveMachine, reason: String) -> Result<()> {
    m.enter(State::RollingBack);

    let pb = spinner("Rolling back — restoring links...");

    // Восстанавливаем хардлинки из repo_path обратно в root_path
    for file in &m.files {
        let repo_file = format!("{}{}", m.config.paths.repo_path.trim_end_matches('/'), file);
        let root_file = format!("{}{}", m.config.paths.root_path.trim_end_matches('/'), file);

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

    if m.exhausted() {
        let msg = format!("remove failed after {} retries: {reason}", MAX_RETRIES);
        m.enter(State::Failed(msg.clone()));
        anyhow::bail!("{msg}");
    }

    m.retries += 1;
    eprintln!(
        "{} retry {}/{}: {reason}",
        "⚠".yellow().bold(),
        m.retries,
        MAX_RETRIES
    );

    // Retry — заново с удаления линков
    state_removing_links(m)
}

fn state_done(m: &mut RemoveMachine) -> Result<()> {
    m.enter(State::Done);
    println!("{} removed {}", "✓".green().bold(), m.name.bold());
    Ok(())
}

// ── Публичное API ─────────────────────────────────────────────────────────────

pub fn run(config: Config, name: String) -> Result<()> {
    let mut machine = RemoveMachine::new(config, name);

    state_reading_meta(&mut machine).map_err(|e| {
        if !matches!(machine.stack.last(), Some(State::Failed(_))) {
            machine.enter(State::Failed(e.to_string()));
        }
        eprintln!(
            "{} failed at state {:?}",
            "✗".red().bold(),
            machine.stack.last()
        );
        e
    })
}

// ── Хелперы ───────────────────────────────────────────────────────────────────
fn spinner(msg: &str) -> ProgressBar {
    let pb = ProgressBar::new_spinner();
    pb.set_style(
        ProgressStyle::default_spinner()
            .tick_strings(&["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"])
            .template("{spinner:.cyan} {msg}")
            .unwrap(),
    );
    pb.set_message(msg.to_owned());
    pb.enable_steady_tick(Duration::from_millis(80));
    pb
}
