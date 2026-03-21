const std = @import("std");
const posix = std.posix;

const c_libs = @cImport({
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
pub fn initSystem(system_paths: SystemPaths, repo_mode: RepoMode, allocator: std.mem.Allocator) !void {
    try checkNotExists(system_paths.ostree_path);
    try checkNotExists(system_paths.repo_path);
    try checkNotExists(system_paths.db_path);

    std.fs.makeDirAbsolute(system_paths.repo_path) catch return InitError.CreateDirFailed;

    std.fs.makeDirAbsolute(system_paths.db_path) catch return InitError.CreateDirFailed;

    try initOstreeRepo(system_paths.ostree_path, repo_mode, allocator);
}

// ── Внутренние функции ────────────────────────────────────────────────────────
fn checkNotExists(path: []const u8) !void {
    std.fs.accessAbsolute(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    return InitError.AlreadyInitialized;
}

fn initOstreeRepo(repo_path: []const u8, repo_mode: RepoMode, allocator: std.mem.Allocator) !void {
    const repo_path_c = try std.fmt.allocPrintZ(allocator, "{s}", .{repo_path});
    defer allocator.free(repo_path_c);

    const struct_g_file = c_libs.g_file_new_for_path(repo_path_c.ptr);
    defer c_libs.g_object_unref(struct_g_file);

    const struct_ostree_repo = c_libs.ostree_repo_new(struct_g_file);
    defer c_libs.g_object_unref(struct_ostree_repo);

    const ostree_mode: c_libs.OstreeRepoMode = switch (repo_mode) {
        .archive => c_libs.OSTREE_REPO_MODE_ARCHIVE,
        .bare => c_libs.OSTREE_REPO_MODE_BARE,
        .bare_user => c_libs.OSTREE_REPO_MODE_BARE_USER,
    };

    var err: ?*c_libs.GError = null;
    if (c_libs.ostree_repo_create(struct_ostree_repo, ostree_mode, null, &err) == 0) {
        if (err) |struct_ge_error| c_libs.g_error_free(struct_ge_error);
        return InitError.OstreeInitFailed;
    }
}
