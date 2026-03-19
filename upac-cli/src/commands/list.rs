use anyhow::Result;

use colored::Colorize;

use crate::config::Config;

use crate::ffi::{CPackageMeta, CSlice, CSliceArray, UpacLib};

// ── FSM ───────────────────────────────────────────────────────────────────────
#[derive(Debug, Clone, PartialEq)]
enum State {
    FetchingList,
    FetchingDetails,
    Printing,
    Done,
    Failed(String),
}

struct ListMachine {
    config: Config,
    versions: bool,
    full: bool,

    names: Vec<String>,
    details: Vec<PackageRow>,

    stack: Vec<State>,
}

struct PackageRow {
    name: String,
    version: String,
    author: String,
    description: String,
    license: String,
    installed_at: i64,
}

impl ListMachine {
    fn new(config: Config, versions: bool, full: bool) -> Self {
        Self {
            config,
            versions,
            full,
            names: Vec::new(),
            details: Vec::new(),
            stack: Vec::new(),
        }
    }

    fn enter(&mut self, state: State) {
        self.stack.push(state);
    }
}

// ── Состояния ─────────────────────────────────────────────────────────────────
fn state_fetching_list(machine: &mut ListMachine) -> Result<()> {
    machine.enter(State::FetchingList);

    let lib = UpacLib::load()?;
    let db_path = CSlice::from_str(&machine.config.paths.db_path);

    let mut list = CSliceArray {
        ptr: std::ptr::null_mut(),
        len: 0,
    };
    let code = unsafe { (lib.db_list_packages)(db_path, &mut list) };
    UpacLib::check(code, "list packages")?;

    let slices = unsafe { std::slice::from_raw_parts(list.ptr, list.len) };
    machine.names = slices
        .iter()
        .map(|string| unsafe { string.as_str().to_owned() })
        .collect();
    unsafe { (lib.list_free)(&mut list) };

    if machine.names.is_empty() {
        println!("{}", "No packages installed.".dimmed());
        machine.enter(State::Done);
        return Ok(());
    }

    if !machine.versions && !machine.full {
        return state_printing(machine);
    }

    state_fetching_details(machine)
}

fn state_fetching_details(machine: &mut ListMachine) -> Result<()> {
    machine.enter(State::FetchingDetails);

    let lib = UpacLib::load()?;
    let db_path = CSlice::from_str(&machine.config.paths.db_path);

    for name in &machine.names {
        let mut c_meta = std::mem::MaybeUninit::<CPackageMeta>::uninit();
        let name_slice = CSlice::from_str(name);

        let code = unsafe { (lib.db_get_meta)(db_path, name_slice, c_meta.as_mut_ptr()) };

        if code != 0 {
            eprintln!("{} could not read metadata for {name}", "⚠".yellow());
            continue;
        }

        let meta = unsafe { c_meta.assume_init() };
        let row = unsafe {
            PackageRow {
                name: meta.name.as_str().to_owned(),
                version: meta.version.as_str().to_owned(),
                author: meta.author.as_str().to_owned(),
                description: meta.description.as_str().to_owned(),
                license: meta.license.as_str().to_owned(),
                installed_at: meta.installed_at,
            }
        };

        let mut meta_owned = meta;
        unsafe { (lib.meta_free)(&mut meta_owned) };

        machine.details.push(row);
    }

    state_printing(machine)
}

fn state_printing(machine: &mut ListMachine) -> Result<()> {
    machine.enter(State::Printing);

    if machine.full {
        for row in &machine.details {
            println!("{}", row.name.bold().green());
            println!("  {} {}", "version:".dimmed(), row.version);
            println!("  {} {}", "author: ".dimmed(), row.author);
            println!("  {} {}", "license:".dimmed(), row.license);
            if !row.description.is_empty() {
                println!("  {} {}", "desc:   ".dimmed(), row.description);
            }
            println!(
                "  {} {}",
                "installed:".dimmed(),
                format_timestamp(row.installed_at)
            );
            println!();
        }
    } else if machine.versions {
        for row in &machine.details {
            println!("{} {}", row.name.bold(), row.version.dimmed());
        }
    } else {
        for name in &machine.names {
            println!("{}", name.bold());
        }
    }

    state_done(machine)
}

fn state_done(machine: &mut ListMachine) -> Result<()> {
    machine.enter(State::Done);
    Ok(())
}

// ── Публичное API ─────────────────────────────────────────────────────────────
pub fn run(config: Config, versions: bool, full: bool) -> Result<()> {
    let mut machine = ListMachine::new(config, versions, full);

    state_fetching_list(&mut machine).map_err(|err| {
        if !matches!(machine.stack.last(), Some(State::Failed(_))) {
            machine.enter(State::Failed(err.to_string()));
        }
        eprintln!(
            "{} failed at state {:?}",
            "✗".red().bold(),
            machine.stack.last()
        );
        err
    })
}

// ── Хелперы ───────────────────────────────────────────────────────────────────
fn format_timestamp(ts: i64) -> String {
    if ts == 0 {
        return "unknown".to_owned();
    }
    format!("unix:{ts}")
}
