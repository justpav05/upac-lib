const std = @import("std");
const posix = std.posix;

const c = @cImport({
    @cInclude("ostree.h");
    @cInclude("glib.h");
    @cInclude("gio/gio.h");
});

// ── Публичные типы ────────────────────────────────────────────────────────────
pub const SystemPaths = struct {
    ostree_path: []const u8,
    repo_path: []const u8,
    db_path: []const u8,
};

/// Режим OStree репозитория.
pub const RepoMode = enum {
    archive,
    bare,
    bare_user,
};

pub const InitError = error{
    AlreadyInitialized,
    CreateDirFailed,
    OstreeInitFailed,
};

// ── Публичное API ─────────────────────────────────────────────────────────────
pub fn initSystem(paths: SystemPaths, mode: RepoMode, allocator: std.mem.Allocator) !void {
    try checkNotExists(paths.ostree_path);
    try checkNotExists(paths.repo_path);
    try checkNotExists(paths.db_path);

    std.fs.makeDirAbsolute(paths.repo_path) catch
        return InitError.CreateDirFailed;

    std.fs.makeDirAbsolute(paths.db_path) catch
        return InitError.CreateDirFailed;

    try initOstreeRepo(paths.ostree_path, mode, allocator);
}

// ── Внутренние функции ────────────────────────────────────────────────────────
fn checkNotExists(path: []const u8) !void {
    std.fs.accessAbsolute(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    return InitError.AlreadyInitialized;
}

fn initOstreeRepo(path: []const u8, mode: RepoMode, allocator: std.mem.Allocator) !void {
    const path_c = try std.fmt.allocPrintZ(allocator, "{s}", .{path});
    defer allocator.free(path_c);

    const file = c.g_file_new_for_path(path_c.ptr);
    defer c.g_object_unref(file);

    const repo = c.ostree_repo_new(file);
    defer c.g_object_unref(repo);

    const ostree_mode: c.OstreeRepoMode = switch (mode) {
        .archive => c.OSTREE_REPO_MODE_ARCHIVE,
        .bare => c.OSTREE_REPO_MODE_BARE,
        .bare_user => c.OSTREE_REPO_MODE_BARE_USER,
    };

    var err: ?*c.GError = null;
    if (c.ostree_repo_create(repo, ostree_mode, null, &err) == 0) {
        if (err) |e| c.g_error_free(e);
        return InitError.OstreeInitFailed;
    }
}
