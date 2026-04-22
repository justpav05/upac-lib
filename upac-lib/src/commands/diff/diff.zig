// ── Imports ─────────────────────────────────────────────────────────────────────
const file = @import("upac-file");

// ── Public imports ───────────────────────────────────────────────────────────
pub const std = @import("std");
pub const c_libs = file.c_libs;

pub const data = @import("upac-data");
pub const ffi = @import("upac-ffi");

// ── Re-exports ───────────────────────────────────────────────────────────────
const files = @import("files.zig");
pub const diffFiles = files.diffFiles;
pub const diffFilesAttributed = files.diffFilesAttributed;

const packages = @import("packages.zig");
pub const diffPackages = packages.diffPackages;
pub const listPackages = packages.listPackages;
pub const listCommits = packages.listCommits;

// ── Imports symbols ──────────────────────────────────────────────────────────
pub usingnamespace @import("symbols.zig");

// ── Errors ───────────────────────────────────────────────────────────────────
pub const DiffError = error{
    PathInvalid,
    RepoOpenFailed,
    CommitNotFound,
    DiffFailed,
    StagingFailed,
    CleanupFailed,
    AllocZPrintFailed,
    FileNotFound,
    Cancelled,
};

// ── Helpers ───────────────────────────────────────────────────────────────────
pub fn resolveCommit(repo: *c_libs.OstreeRepo, commit_hash_c: [:0]const u8) !DiffError![*:0]u8 {
    var gerror: ?*c_libs.GError = null;
    defer if (gerror) |err| c_libs.g_error_free(err);

    var resolved: ?[*:0]u8 = null;

    if (c_libs.ostree_repo_resolve_rev(repo, commit_hash_c.ptr, 0, &resolved, &gerror) == 0) return DiffError.CommitNotFound;

    return resolved orelse DiffError.CommitNotFound;
}

pub fn onCancelSignal(user_data: c_libs.gpointer) callconv(.C) c_libs.gboolean {
    const cancellable = @as(*c_libs.GCancellable, @ptrCast(@alignCast(user_data)));
    c_libs.g_cancellable_cancel(cancellable);
    return c_libs.G_SOURCE_REMOVE;
}

pub fn signalLoopThread(loop: *c_libs.GMainLoop) void {
    c_libs.g_main_loop_run(loop);
}
