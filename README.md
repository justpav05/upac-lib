# upac

A modular package management library for Linux systems with OSTree integration.

## Overview

Upac is a package manager for Linux-compatible systems. It manages the updating, removal, and installation of various package formats using different backends. It also supports OSTree for rolling back the state of binaries to specific commits.

Upac-cli is a package management interface written in Rust that utilizes upac-lib as its backend. It supports formatted input and output, as well as a polished installation interface and the display of errors and debugging information.

Upac-lib is a low-level package management library written in Zig, designed to be embedded into package managers through a stable C ABI. It handles the core operations of package installation, database management, and system snapshotting — without imposing any policy on how packages are fetched or what format they come in.

The library is intentionally split into independent components: backends handle format-specific unpacking, the core library handles installation and database operations, and OStree integration is optional.

## Components

### Core Library (`upac-lib`)

The core library exposes a C-compatible ABI through `libupac.so`. All strings cross the boundary as `{ ptr, len }` pairs rather than null-terminated C strings. All functions return an integer error code.

### Backends

Backends are separate shared libraries that handle format-specific package unpacking. Each backend receives a package path, an output directory, and a SHA-256 checksum; it verifies the checksum, extracts the package, parses the metadata, and returns a `PackageMeta` struct.

**`upac-alpm-backend`** handles Arch Linux packages (`.pkg.tar.zst`, `.pkg.tar.xz`, `.pkg.tar.gz`). Metadata is read from `.PKGINFO` inside the archive.

**`upac-rpm-backend`** handles Fedora, RHEL, and openSUSE packages (.rpm). Metadata is read from the RPM header and internal cpio archive structures.

**`upac-deb-backend`** handles Ubuntu, Debian, etc. (.deb). Metadata is read from the control file and internal tar archive structures.

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
