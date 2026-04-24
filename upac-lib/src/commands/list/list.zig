// ── Imports ─────────────────────────────────────────────────────────────────────
const file = @import("upac-file");

// ── Public imports ───────────────────────────────────────────────────────────
pub const std = @import("std");
pub const c_libs = file.c_libs;

pub const data = @import("upac-data");
pub const ffi = @import("upac-ffi");

const PackageMeta = ffi.PackageMeta;
const CommitEntry = ffi.CommitEntry;

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

// Returns the installed package metadata list from the latest commit on a branch
pub fn listPackages(repo_path: []const u8, branch: []const u8, db_path: []const u8, cancellable: ?*c_libs.GCancellable, allocator: std.mem.Allocator) DiffError![]PackageMeta {
    var gerror: ?*c_libs.GError = null;
    defer if (gerror) |err| c_libs.g_error_free(err);

    const repo_path_c = try check(allocator.dupeZ(u8, repo_path), DiffError.AllocZPrintFailed);
    defer allocator.free(repo_path_c);

    const branch_c = try check(allocator.dupeZ(u8, branch), DiffError.AllocZPrintFailed);
    defer allocator.free(branch_c);

    const repo = try openRepo(repo_path, cancellable, &gerror, allocator);
    defer c_libs.g_object_unref(repo);

    var head_checksum: ?[*:0]u8 = null;
    if (c_libs.ostree_repo_resolve_rev(repo, branch_c, 1, &head_checksum, null) == 0 or head_checksum == null) return &.{};
    defer c_libs.g_free(@ptrCast(head_checksum));

    const body = try check(getRefBody(repo, branch, cancellable, allocator), DiffError.CommitNotFound) orelse return &.{};
    defer allocator.free(body);

    var package_map = parsePackageBody(body, allocator) catch return &.{};
    defer freeStringMap(&package_map, allocator);

    var result_package_metas = std.ArrayList(PackageMeta).init(allocator);
    errdefer {
        for (result_package_metas.items) |package_meta| data.freePackageMeta(package_meta, allocator);
        result_package_metas.deinit();
    }

    var package_map_iter = package_map.iterator();
    while (package_map_iter.next()) |entry| {
        const package_meta = data.readMeta(db_path, entry.value_ptr.*, allocator) catch continue;
        try check(result_package_metas.append(package_meta), DiffError.AllocZPrintFailed);
    }

    return try check(result_package_metas.toOwnedSlice(), DiffError.AllocZPrintFailed);
}

// Walks the commit chain of a branch and returns all commits as a slice
pub fn listCommits(repo_path: []const u8, branch: []const u8, cancellable: ?*c_libs.GCancellable, allocator: std.mem.Allocator) DiffError![]CommitEntry {
    var gerror: ?*c_libs.GError = null;
    defer if (gerror) |err| c_libs.g_error_free(err);

    const branch_c = try check(allocator.dupeZ(u8, branch), DiffError.AllocZPrintFailed);
    defer allocator.free(branch_c);

    const repo = try openRepo(repo_path, cancellable, &gerror, allocator);
    defer c_libs.g_object_unref(repo);

    var entries = std.ArrayList(CommitEntry).init(allocator);
    errdefer {
        for (entries.items) |entry| {
            allocator.free(entry.checksum);
            allocator.free(entry.subject);
        }
        entries.deinit();
    }

    var current_checksum: ?[*:0]u8 = null;
    if (c_libs.ostree_repo_resolve_rev(repo, branch_c.ptr, 0, &current_checksum, &gerror) == 0) return try check(entries.toOwnedSlice(), DiffError.AllocZPrintFailed);

    var checksum = current_checksum;
    var is_first = true;

    while (checksum) |current_cs| {
        var commit_variant: ?*c_libs.GVariant = null;
        if (c_libs.ostree_repo_load_variant(repo, c_libs.OSTREE_OBJECT_TYPE_COMMIT, current_cs, &commit_variant, &gerror) == 0) {
            if (!is_first) c_libs.g_free(@ptrCast(current_cs));
            break;
        }
        defer if (commit_variant) |variant| c_libs.g_variant_unref(variant);

        const subject_variant = c_libs.g_variant_get_child_value(commit_variant, 3);
        defer if (subject_variant) |variant| c_libs.g_variant_unref(variant);

        var subject_len: usize = 0;
        const subject_ptr = c_libs.g_variant_get_string(subject_variant, &subject_len);

        const checksum_dupe = try check(allocator.dupe(u8, std.mem.span(current_cs)), DiffError.AllocZPrintFailed);
        const subject_dupe = try check(allocator.dupe(u8, subject_ptr[0..subject_len]), DiffError.AllocZPrintFailed);

        try check(entries.append(.{ .checksum = checksum_dupe, .subject = subject_dupe }), DiffError.AllocZPrintFailed);

        const parent = c_libs.ostree_commit_get_parent(commit_variant);
        if (!is_first) c_libs.g_free(@ptrCast(current_cs));

        is_first = false;
        checksum = parent;
    }

    if (current_checksum) |cs| c_libs.g_free(@ptrCast(cs));
    return try check(entries.toOwnedSlice(), DiffError.AllocZPrintFailed);
}

// ── Private helpers ───────────────────────────────────────────────────────────
pub fn getRefBody(repo: *c_libs.OstreeRepo, ostree_ref: []const u8, cancellable: ?*c_libs.GCancellable, allocator: std.mem.Allocator) DiffError!?[]const u8 {
    var gerror: ?*c_libs.GError = null;
    defer if (gerror) |err| c_libs.g_error_free(err);

    _ = cancellable;

    const ostree_ref_c = try check(allocator.dupeZ(u8, ostree_ref), DiffError.AllocZPrintFailed);
    defer allocator.free(ostree_ref_c);

    var checksum: ?[*:0]u8 = null;
    defer c_libs.g_free(@ptrCast(checksum));

    if (c_libs.ostree_repo_resolve_rev(repo, ostree_ref_c.ptr, 1, &checksum, &gerror) == 0 or checksum == null) return null;

    var commit_variant: ?*c_libs.GVariant = null;
    defer if (commit_variant) |variant| c_libs.g_variant_unref(variant);

    if (c_libs.ostree_repo_load_variant(repo, c_libs.OSTREE_OBJECT_TYPE_COMMIT, checksum, &commit_variant, &gerror) == 0) return null;

    const body_variant = c_libs.g_variant_get_child_value(commit_variant, 4);
    defer if (body_variant) |variant| c_libs.g_variant_unref(variant);

    var body_len: usize = 0;
    const body_ptr = c_libs.g_variant_get_string(body_variant, &body_len);

    return try check(allocator.dupe(u8, body_ptr[0..body_len]), DiffError.AllocZPrintFailed);
}

pub fn parsePackageBody(body: []const u8, allocator: std.mem.Allocator) DiffError!std.StringHashMap([]const u8) {
    var map = std.StringHashMap([]const u8).init(allocator);
    errdefer freeStringMap(&map, allocator);

    var line_iter = std.mem.splitScalar(u8, body, '\n');
    while (line_iter.next()) |line| {
        const trimmed_line = std.mem.trim(u8, line, " \t\r");
        if (trimmed_line.len == 0) continue;

        const separator_index = std.mem.indexOfScalar(u8, trimmed_line, ' ') orelse continue;
        const name = trimmed_line[0..separator_index];
        const checksum = std.mem.trim(u8, trimmed_line[separator_index + 1 ..], " \t");

        if (name.len == 0 or checksum.len == 0) continue;

        const name_dupe = try check(allocator.dupe(u8, name), DiffError.AllocZPrintFailed);
        const checksum_dupe = try check(allocator.dupe(u8, checksum), DiffError.AllocZPrintFailed);

        try check(map.put(name_dupe, checksum_dupe), DiffError.AllocZPrintFailed);
    }
    return map;
}

pub fn freeStringMap(map: *std.StringHashMap([]const u8), allocator: std.mem.Allocator) void {
    var map_iter = map.iterator();
    while (map_iter.next()) |entry| {
        allocator.free(entry.key_ptr.*);
        allocator.free(entry.value_ptr.*);
    }
    map.deinit();
}

fn openRepo(repo_path: []const u8, cancellable: ?*c_libs.GCancellable, gerror: *?*c_libs.GError, allocator: std.mem.Allocator) DiffError!*c_libs.OstreeRepo {
    const repo_path_c = try check(allocator.dupeZ(u8, repo_path), DiffError.AllocZPrintFailed);
    defer allocator.free(repo_path_c);

    const gfile = c_libs.g_file_new_for_path(repo_path_c.ptr);
    defer c_libs.g_object_unref(gfile);

    const repo = c_libs.ostree_repo_new(gfile);
    if (c_libs.ostree_repo_open(repo, cancellable, gerror) == 0) {
        c_libs.g_object_unref(repo);
        return DiffError.RepoOpenFailed;
    }
    return try unwrap(repo, DiffError.RepoOpenFailed);
}

pub inline fn unwrap(value: anytype, comptime err: DiffError) DiffError!@typeInfo(@TypeOf(value)).Optional.child {
    return value orelse err;
}

pub inline fn check(value: anytype, comptime err: DiffError) DiffError!@typeInfo(@TypeOf(value)).ErrorUnion.payload {
    return value catch err;
}

pub fn onCancelSignal(user_data: c_libs.gpointer) callconv(.C) c_libs.gboolean {
    const cancellable = @as(*c_libs.GCancellable, @ptrCast(@alignCast(user_data)));
    c_libs.g_cancellable_cancel(cancellable);
    return c_libs.G_SOURCE_REMOVE;
}

pub fn signalLoopThread(loop: *c_libs.GMainLoop) void {
    c_libs.g_main_loop_run(loop);
}
