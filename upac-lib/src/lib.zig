// ── Imports ─────────────────────────────────────────────────────────────────────
const std = @import("std");

const file = @import("upac-file");
const c_libs = file.c_libs;

const ffi = @import("upac-ffi");

const data = @import("upac-data");

// ── Reimports symbols ─────────────────────────────────────────────────────────────────────
pub usingnamespace @import("upac-installer");
pub usingnamespace @import("upac-uninstaller");
pub usingnamespace @import("upac-rollback");
pub usingnamespace @import("upac-list");
pub usingnamespace @import("upac-diff");
pub usingnamespace @import("upac-init");

// Finalizes the allocator and outputs a warning to the console if any memory leaks were detected during program execution
pub export fn upac_deinit() callconv(.C) void {
    ffi.deinit();
}
