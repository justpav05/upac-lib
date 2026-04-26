// ── Imports ─────────────────────────────────────────────────────────────────────
const ffi = @import("upac-ffi");

pub fn request_cancel() callconv(.c) void {
    ffi.global_cancel.store(true, .release);
}

pub fn reset_cancel() callconv(.c) void {
    ffi.global_cancel.store(false, .release);
}

// Finalizes the allocator and outputs a warning to the console if any memory leaks were detected during program execution
pub fn deinit() callconv(.c) void {
    ffi.deinit();
}
