# upac

A modular package management library for Linux systems with OSTree integration.

## Overview

Upac is a package manager for Linux-compatible systems. It manages the updating, removal, and installation of various package formats using different backends. It also supports OSTree for rolling back the state of binaries to specific commits.

Upac-cli is a package management interface written in Rust that utilizes upac-lib as its backend. It supports formatted input and output, as well as a polished installation interface and the display of errors and debugging information.

Upac-lib is a low-level package management library written in Zig, designed to be embedded into package managers through a stable C ABI. It handles the core operations of package installation, database management, and system snapshotting — without imposing any policy on how packages are fetched or what format they come in.

The library is intentionally split into independent components: backends handle format-specific unpacking, the core library handles installation and database operations, and OStree integration is optional.

## Architecture

```
upac-lib/                  Core library (.so)
├── lock/                  File-descriptor based locking (flock)
├── database/              Package database (TOML files + index)
├── installer/             File copying, hardlinking, permissions
├── uninstaller/           File deleting, relinking
├── ostree/                OStree commit, diff, rollback
├── parser/                Parse toml files
├── ffi/                   C ABI exports
└── init                   System directory initialization

upac-alpm-backend/         Arch Linux package backend (.so)
└── src/                   Verification, extraction, .PKGINFO parsing

upac-rpm-backend/          Fedora Linux like package backend (.so)
└── src/                   Verification, extraction, archive parsing

upac-deb-backend/          Debian Linux like package backend (.so)
└── src/                   Verification, extraction, archive parsing

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

**`upac-rpm-backend`** handles Fedora, RHEL, and openSUSE packages (.rpm). Metadata is read from the RPM header and internal cpio archive structures.

Adding support for a new package format means writing a new backend `.so` — the core library does not need to change.

### CLI (`upac-cli`)

A command-line frontend written in Rust that dynamically loads `libupac.so` and the appropriate backend at runtime using `libloading`. The backend is selected by file extension or explicit `--backend` flag or automaticly.

## Building

**Prerequisites**

- Zig 0.13
- Rust (latest stable)
- `libostree-1` (required for OStree features, need fot building upac-lib)
- `libarchive` (required for backends)
- `libglib-2.0`, `libgio-2.0` (pulled in by libostree)

**Build everything**

```sh
make build
```

**Build individual components**

```sh
make build-lib        # builds upac-lib → upac-lib/zig-out/lib/libupac.so
make build-backends   # builds upac-alpm-backend → upac-alpm-backend/zig-out/lib/libupac-backend-arch.so
make build-cli        # builds upac-cli → upac-cli/target/debug/upac
make pkg-arch         # builds upac-package for Arch Linux → pkg/arch/upac-{vertion}-x86_64.pkg.tar.zst
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
