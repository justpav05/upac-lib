const std = @import("std");
const posix = std.posix;

const types = @import("upac-file");
const c_libs = types.c_libs;

pub const ffi = @import("upac-ffi");

// ── Imports symbols ─────────────────────────────────────────────────────────────────────
pub usingnamespace @import("symbols.zig");

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
    NotADirectory,
    CreateDirFailed,
    OstreeInitFailed,
    DirectoryNotEmpty,
};

// ── Public API ─────────────────────────────────────────────────────────────
pub fn initSystem(system_paths: SystemPaths, repo_mode: RepoMode, branch: []const u8, allocator: std.mem.Allocator) !void {
    if (!try checkDirExists(system_paths.root_path)) {
        return InitError.RootNotFound;
    }

    if (try checkFileExists(system_paths.repo_path)) {
        return InitError.NotADirectory;
    }

    if (!try checkDirExists(system_paths.repo_path)) {
        std.fs.makeDirAbsolute(system_paths.repo_path) catch return InitError.CreateDirFailed;
    } else {
        var dir = try std.fs.openDirAbsolute(system_paths.repo_path, .{ .iterate = true });
        defer dir.close();

        var iterator = dir.iterate();
        var is_empty = true;
        while (try iterator.next()) |entry| {
            is_empty = false;
            if (std.mem.eql(u8, entry.name, "config")) return InitError.AlreadyInitialized;
        }
        if (!is_empty) return InitError.DirectoryNotEmpty;
    }

    try initOstreeRepo(system_paths.repo_path, repo_mode, branch, allocator);
}

// ── Helpers funchtions ────────────────────────────────────────────────────────
fn checkDirExists(path: []const u8) !bool {
    const stat = std.fs.cwd().statFile(path) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };

    return stat.kind == .directory;
}

fn checkFileExists(path: []const u8) !bool {
    const stat = std.fs.cwd().statFile(path) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };

    return stat.kind == .file;
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
