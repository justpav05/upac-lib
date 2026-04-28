// ── Public imports ───────────────────────────────────────────────────────────
pub const std = @import("std");

pub const data = @import("upac-data");
pub const ffi = @import("upac-ffi");
pub const c_libs = ffi.c_libs;

const PackageMeta = ffi.PackageMeta;
const CommitEntry = ffi.CommitEntry;

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
pub fn listPackages(repo_path_c: [*:0]u8, branch_c: [*:0]u8, db_path: []const u8, cancellable: [*c]c_libs.GCancellable, gerror: [*c]c_libs.GError, allocator: std.mem.Allocator) DiffError![]PackageMeta {
    const repo = try openRepo(repo_path_c, cancellable, &gerror);
    defer c_libs.g_object_unref(repo);

    var head_checksum: [*c]u8 = null;
    if (c_libs.ostree_repo_resolve_rev(repo, branch_c, 1, &head_checksum, &gerror) == 0 or head_checksum == null) return &.{};
    defer if (head_checksum != null) c_libs.g_free(head_checksum);

    const body = try check(getRefBody(repo, branch_c, &gerror, allocator), DiffError.CommitNotFound) orelse return &.{};
    defer allocator.free(body);

    var package_map = parsePackageBody(body, allocator) catch return &.{};
    defer freeStringMap(&package_map, allocator);

    var result_package_metas = std.ArrayList(PackageMeta).empty;
    errdefer {
        for (result_package_metas.items) |package_meta| data.freePackageMeta(package_meta, allocator);
        result_package_metas.deinit(allocator);
    }

    var package_map_iter = package_map.iterator();
    while (package_map_iter.next()) |entry| {
        const package_meta = data.readMeta(db_path, entry.value_ptr.*, allocator) catch continue;
        try check(result_package_metas.append(allocator, package_meta), DiffError.AllocZPrintFailed);
    }

    return try check(result_package_metas.toOwnedSlice(allocator), DiffError.AllocZPrintFailed);
}

// Walks the commit chain of a branch and returns all commits as a slice
pub fn listCommits(repo_path_c: [*:0]u8, branch_c: [*:0]u8, gerror: [*c]c_libs.GError, allocator: std.mem.Allocator) DiffError![]CommitEntry {
    const cancellable = c_libs.g_cancellable_new() orelse return DiffError.Cancelled;
    defer c_libs.g_object_unref(cancellable);

    const repo = try openRepo(repo_path_c, cancellable, &gerror);
    defer c_libs.g_object_unref(repo);

    var entries = std.ArrayList(CommitEntry).empty;
    errdefer {
        for (entries.items) |entry| {
            allocator.free(entry.checksum);
            allocator.free(entry.subject);
        }
        entries.deinit(allocator);
    }

    var current_checksum: [*c]u8 = null;
    defer if (current_checksum != null) c_libs.g_free(current_checksum);
    if (c_libs.ostree_repo_resolve_rev(repo, branch_c, 0, &current_checksum, &gerror) == 0) return try check(entries.toOwnedSlice(allocator), DiffError.AllocZPrintFailed);

    var checksum = current_checksum;
    var is_first = true;

    while (checksum != null) {
        try checkCancel(cancellable, gerror);

        var commit_variant: ?*c_libs.GVariant = null;
        if (c_libs.ostree_repo_load_variant(repo, c_libs.OSTREE_OBJECT_TYPE_COMMIT, checksum, &commit_variant, &gerror) == 0) {
            if (!is_first) c_libs.g_free(checksum);
            break;
        }
        defer if (commit_variant) |variant| c_libs.g_variant_unref(variant);

        const subject_variant = c_libs.g_variant_get_child_value(commit_variant, 3);
        defer if (subject_variant) |variant| c_libs.g_variant_unref(variant);

        var subject_len: usize = 0;
        const subject_ptr = c_libs.g_variant_get_string(subject_variant, &subject_len);

        const checksum_dupe = try check(allocator.dupe(u8, std.mem.span(checksum)), DiffError.AllocZPrintFailed);
        const subject_dupe = try check(allocator.dupe(u8, subject_ptr[0..subject_len]), DiffError.AllocZPrintFailed);

        try check(entries.append(allocator, .{ .checksum = checksum_dupe, .subject = subject_dupe }), DiffError.AllocZPrintFailed);

        const parent = c_libs.ostree_commit_get_parent(commit_variant);
        if (!is_first) c_libs.g_free(checksum);

        is_first = false;
        checksum = parent;
    }

    return try check(entries.toOwnedSlice(allocator), DiffError.AllocZPrintFailed);
}

// ── Private helpers ───────────────────────────────────────────────────────────
pub fn getRefBody(repo: *c_libs.OstreeRepo, ostree_ref_c: [*:0]u8, gerror: *[*c]c_libs.GError, allocator: std.mem.Allocator) DiffError!?[]const u8 {
    var checksum: [*c]u8 = null;
    defer if (checksum != null) c_libs.g_free(checksum);

    if (c_libs.ostree_repo_resolve_rev(repo, ostree_ref_c, 1, &checksum, gerror) == 0 or checksum == null) return null;

    var commit_variant: ?*c_libs.GVariant = null;
    defer if (commit_variant) |variant| c_libs.g_variant_unref(variant);

    if (c_libs.ostree_repo_load_variant(repo, c_libs.OSTREE_OBJECT_TYPE_COMMIT, checksum, &commit_variant, gerror) == 0) return null;

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

fn openRepo(repo_path_c: [*:0]u8, cancellable: ?*c_libs.GCancellable, gerror: *[*c]c_libs.GError) DiffError!*c_libs.OstreeRepo {
    const gfile = c_libs.g_file_new_for_path(repo_path_c);
    defer c_libs.g_object_unref(gfile);

    const repo = c_libs.ostree_repo_new(gfile);
    if (c_libs.ostree_repo_open(repo, cancellable, gerror) == 0) {
        c_libs.g_object_unref(repo);
        return DiffError.RepoOpenFailed;
    }
    return try unwrap(repo, DiffError.RepoOpenFailed);
}

fn checkCancel(cancellable: *[*c]c_libs.GCancellable, gerror: [*c]c_libs.GError) DiffError!void {
    if (!ffi.isCancelRequested()) return;
    if (gerror == null) return;
    c_libs.g_cancellable_cancel(cancellable);
    return DiffError.Cancelled;
}

pub inline fn unwrap(value: anytype, comptime err: DiffError) DiffError!@typeInfo(@TypeOf(value)).optional.child {
    return value orelse err;
}

pub inline fn check(value: anytype, comptime err: DiffError) DiffError!@typeInfo(@TypeOf(value)).error_union.payload {
    return value catch err;
}
