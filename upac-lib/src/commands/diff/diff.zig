// ── Public imports ───────────────────────────────────────────────────────────
pub const std = @import("std");

pub const data = @import("upac-data");
pub const ffi = @import("upac-ffi");
pub const c_libs = ffi.c_libs;

// ── Re-exports ───────────────────────────────────────────────────────────────
pub const files = @import("files.zig");
pub const packages = @import("packages.zig");

pub const diffPackages = packages.diffPackages;

// ── Imports symbols ──────────────────────────────────────────────────────────

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
pub fn resolveCommit(repo: *c_libs.OstreeRepo, commit_hash_c: [:0]const u8, gerror: *[*c]c_libs.GError) DiffError![*c]u8 {
    var resolved: ?[*c]u8 = null;

    if (c_libs.ostree_repo_resolve_rev(repo, commit_hash_c.ptr, 0, &resolved, &gerror) == 0) return DiffError.CommitNotFound;

    try unwrap(resolved, DiffError.CommitNotFound);
}

pub fn openRepo(repo_path_c: [*:0]u8, cancellable: [*c]c_libs.GCancellable, gerror: *[*c]c_libs.GError) DiffError!*c_libs.OstreeRepo {
    const gfile = c_libs.g_file_new_for_path(repo_path_c);
    defer c_libs.g_object_unref(gfile);

    const repo = c_libs.ostree_repo_new(gfile);
    if (c_libs.ostree_repo_open(repo, cancellable, gerror) == 0) {
        c_libs.g_object_unref(repo);
        return DiffError.RepoOpenFailed;
    }
    return try unwrap(repo, DiffError.RepoOpenFailed);
}

pub inline fn unwrap(value: anytype, comptime err: DiffError) DiffError!@typeInfo(@TypeOf(value)).optional.child {
    return value orelse err;
}

pub inline fn check(value: anytype, comptime err: DiffError) DiffError!@typeInfo(@TypeOf(value)).error_union.payload {
    return value catch err;
}

fn isBroked(gerror: *?*c_libs.GError, cancellable: [*c]c_libs.GCancellable) DiffError!void {
    if (gerror != null) {
        const is_cancel_error = gerror.domain == c_libs.g_io_error_quark() and
            gerror.code == c_libs.G_IO_ERROR_CANCELLED;

        c_libs.g_error_free(gerror);
    }

    const is_cancelled = ffi.isCancelRequested() or
        (if (self.cancellable) |cancellable| c_libs.g_cancellable_is_cancelled(cancellable) != 0 else false);

    if (is_cancelled) {
        if (self.cancellable) |cancellable| c_libs.g_cancellable_cancel(cancellable);
        stateFailed(self);
        return InstallerError.Cancelled;
    }

    if (self.exhausted()) {
        stateFailed(self);
        return InstallerError.MaxRetriesExceeded;
    }
}
