const std = @import("std");
const posix = std.posix;

const types = @import("upac-file");
const c_libs = types.c_libs;

// ── Public types ────────────────────────────────────────────────────────────
pub const SystemPaths = struct {
    repo_path: []const u8,
    root_path: []const u8,
};

pub const RepoMode = enum {
    archive,
    bare,
    bare_user,
};

pub const InitError = error{
    AlreadyInitialized,
    RootNotFound,
    CreateDirFailed,
    OstreeInitFailed,
};

// ── Public API ─────────────────────────────────────────────────────────────
pub fn initSystem(system_paths: SystemPaths, repo_mode: RepoMode, branch: []const u8, allocator: std.mem.Allocator) !void {
    try checkExists(system_paths.root_path);

    std.fs.makeDirAbsolute(system_paths.repo_path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return InitError.CreateDirFailed,
    };

    try initOstreeRepo(system_paths.repo_path, repo_mode, branch, allocator);
}

// ── Helpers funchtions ────────────────────────────────────────────────────────
fn checkExists(path: []const u8) !void {
    std.fs.accessAbsolute(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return InitError.RootNotFound,
        else => return err,
    };
}

fn initOstreeRepo(repo_path: []const u8, repo_mode: RepoMode, branch: []const u8, allocator: std.mem.Allocator) !void {
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

    var gerr: ?*c_libs.GError = null;
    if (c_libs.ostree_repo_create(struct_ostree_repo, ostree_mode, null, &gerr) == 0) {
        if (gerr) |err| c_libs.g_error_free(err);
        return InitError.OstreeInitFailed;
    }

    var transaction_err: ?*c_libs.GError = null;
    if (c_libs.ostree_repo_prepare_transaction(struct_ostree_repo, null, null, &transaction_err) == 0) {
        if (transaction_err) |e| c_libs.g_error_free(e);
        return InitError.OstreeInitFailed;
    }

    const branch_c = try std.fmt.allocPrintZ(allocator, "{s}", .{branch});
    defer allocator.free(branch_c);

    c_libs.ostree_repo_transaction_set_ref(struct_ostree_repo, null, branch_c.ptr, null);

    if (c_libs.ostree_repo_commit_transaction(struct_ostree_repo, null, null, &gerr) == 0) {
        if (gerr) |err| c_libs.g_error_free(err);
        _ = c_libs.ostree_repo_abort_transaction(struct_ostree_repo, null, null);
        return InitError.OstreeInitFailed;
    }
}
