# upac

A modular package management library for Linux systems with OStree integration.

## Overview

upac is a low-level package management library written in Zig, designed to be embedded into package managers through a stable C ABI. It handles the core operations of package installation, database management, and system snapshotting — without imposing any policy on how packages are fetched or what format they come in.

The library is intentionally split into independent components: backends handle format-specific unpacking, the core library handles installation and database operations, and OStree integration is entirely optional.

## Architecture

```
upac-lib/                  Core library (.so)
├── lock/                  File-descriptor based locking (flock)
├── database/              Package database (TOML files + index)
├── installer/             File copying, hardlinking, permissions
├── ostree/                OStree commit, diff, rollback
├── init/                  System directory initialization
└── ffi/                   C ABI exports

upac-alpm-backend/         Arch Linux package backend (.so)
└── src/                   Verification, extraction, .PKGINFO parsing

upac-cli/                  Command-line interface (Rust)
```

Each component is implemented as a finite state machine. State transitions are explicit — each function either calls the next state directly or returns an error, making the control flow easy to trace and reason about.

## Components

### Core Library (`upac-lib`)

The core library exposes a C-compatible ABI through `libupac.so`. All strings cross the boundary as `{ ptr, len }` pairs rather than null-terminated C strings. All functions return an integer error code; `0` means success.

**Database** — Stores installed package metadata and file lists as TOML files in a directory. Each package gets its own file; an `index.toml` tracks which packages are installed. All writes are atomic (write to `.tmp`, then rename).

**Installer** — Copies package files into the OStree repository directory, then hardlinks them into the root filesystem. Supports configurable retry limits and automatic rollback to the previous state on `FileNotFound` errors.

**OStree** — Optional snapshotting layer. After installation, the caller may commit the current state of the repository directory to an OStree repo. Diff and rollback operations are also available.

**Init** — One-time system initialization. Creates the database directory, repository directory, and OStree repository with a configurable mode (archive, bare, bare-user).

### Backends

Backends are separate shared libraries that handle format-specific package unpacking. Each backend receives a package path, an output directory, and a SHA-256 checksum; it verifies the checksum, extracts the package, parses the metadata, and returns a `PackageMeta` struct.

**`upac-alpm-backend`** handles Arch Linux packages (`.pkg.tar.zst`, `.pkg.tar.xz`, `.pkg.tar.gz`). Metadata is read from `.PKGINFO` inside the archive.

Adding support for a new package format means writing a new backend `.so` — the core library does not need to change.

### CLI (`upac-cli`)

A command-line frontend written in Rust that dynamically loads `libupac.so` and the appropriate backend at runtime using `libloading`. The backend is selected by file extension or explicit `--backend` flag.

## Building

**Prerequisites**

- Zig 0.13
- Rust (latest stable)
- `libostree-1` (optional, required for OStree features)
- `libarchive` (required for ALPM backend)
- `libglib-2.0`, `libgio-2.0` (pulled in by libostree)

**Build everything**

```sh
make
```

**Build individual components**

```sh
make lib        # builds upac-lib → upac-lib/zig-out/lib/libupac.so
make backends   # builds upac-alpm-backend → upac-alpm-backend/zig-out/lib/libupac-backend-arch.so
make cli        # builds upac-cli → upac-cli/target/debug/upac
```

**Run tests**

```sh
cd upac-lib && zig build test
cd upac-alpm-backend && zig build test
```

**Clean**

```sh
make clean
```

## Design Decisions

**Finite state machines everywhere.** Every non-trivial operation is modeled as an FSM where each state is a function that calls the next state directly. This makes the transition graph explicit and keeps error handling close to where errors occur.

**No central dispatcher.** There is no event loop or scheduler. The FSM runs by direct function calls, with self-loops for retry logic and backward transitions for rollback. The call stack *is* the state history.

**Hardlinks over copies.** The installer copies files into the OStree repository directory once, then hardlinks them into the root filesystem. This avoids redundant disk usage and keeps the repository in sync with what is actually installed.

**Stable C ABI.** All public functions use `extern "C"` calling convention with `repr(C)` types. Strings are `{ ptr: [*]const u8, len: usize }` pairs. This allows the library to be called from any language with C FFI support.

**Optional OStree.** The installer has no knowledge of OStree. The caller decides whether to snapshot after installation. This keeps the installer simple and makes OStree genuinely optional.

**Per-format backends.** Package format support is isolated in separate shared libraries. The core library never parses package archives. This means adding RPM or Debian support does not require touching the core.

## FFI Usage

The C ABI is defined in `upac-lib/src/ffi/`. A minimal example in Rust using `libloading`:

```rust
#[repr(C)]
struct CSlice {
    ptr: *const u8,
    len: usize,
}

impl CSlice {
    fn from_str(s: &str) -> Self {
        Self { ptr: s.as_ptr(), len: s.len() }
    }
}

// Load the library
let lib = unsafe { libloading::Library::new("libupac.so") }?;

// Resolve a symbol
let list_packages: libloading::Symbol<unsafe extern "C" fn(CSlice, *mut CSliceArray) -> i32> =
    unsafe { lib.get(b"upac_db_list_packages") }?;
```

All memory allocated by the library must be freed using the corresponding `upac_*_free` function. Never pass library-allocated pointers to the system allocator.

## Error Codes

| Range | Component |
|-------|-----------|
| 0 | Success |
| 1–9 | General errors |
| 10–19 | Lock |
| 20–29 | Database |
| 30–39 | Installer |
| 40–49 | OStree |
| 50–59 | Init |

## License

TBD