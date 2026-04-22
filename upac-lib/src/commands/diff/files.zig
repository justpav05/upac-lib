// ── Imports ─────────────────────────────────────────────────────────────────────
const std = @import("std");

const diff = @import("diff.zig");
const c_libs = diff.c_libs;
const data = diff.data;

const DiffEntry = diff.ffi.DiffEntry;
const AttributedDiffEntry = diff.ffi.AttributedDiffEntry;

const DiffError = diff.DiffError;

const packages = @import("packages.zig");

// Checks out two refs and compares their file trees using ostree_diff_dirs
pub fn diffFiles(repo_path: []const u8, from_ref: []const u8, to_ref: []const u8, root_path: []const u8, cancellable: ?*c_libs.GCancellable, allocator: std.mem.Allocator) DiffError![]DiffEntry {
    var gerror: ?*c_libs.GError = null;
    defer if (gerror) |err| c_libs.g_error_free(err);

    const repo_path_c = std.fmt.allocPrintZ(allocator, "{s}", .{repo_path}) catch return diff.DiffError.AllocZPrintFailed;
    defer allocator.free(repo_path_c);

    const from_ref_c = std.fmt.allocPrintZ(allocator, "{s}", .{from_ref}) catch return diff.DiffError.AllocZPrintFailed;
    defer allocator.free(from_ref_c);

    const to_ref_c = std.fmt.allocPrintZ(allocator, "{s}", .{to_ref}) catch return diff.DiffError.AllocZPrintFailed;
    defer allocator.free(to_ref_c);

    const gfile = c_libs.g_file_new_for_path(repo_path_c.ptr);
    defer c_libs.g_object_unref(gfile);

    const repo = c_libs.ostree_repo_new(gfile);
    defer c_libs.g_object_unref(repo);

    if (c_libs.ostree_repo_open(repo, cancellable, &gerror) == 0) return diff.DiffError.RepoOpenFailed;

    const timestamp = std.time.milliTimestamp();

    const from_checkout_path = std.fmt.allocPrintZ(allocator, "{s}/upac_diff_from_{d}", .{ root_path, timestamp }) catch return diff.DiffError.AllocZPrintFailed;
    defer allocator.free(from_checkout_path);
    defer std.fs.deleteTreeAbsolute(from_checkout_path) catch {};

    const to_checkout_path = std.fmt.allocPrintZ(allocator, "{s}/upac_diff_to_{d}", .{ root_path, timestamp + 1 }) catch return diff.DiffError.AllocZPrintFailed;
    defer allocator.free(to_checkout_path);
    defer std.fs.deleteTreeAbsolute(to_checkout_path) catch {};

    try checkoutRef(repo.?, from_ref_c, from_checkout_path, cancellable);

    if (cancellable) |cancel| {
        if (c_libs.g_cancellable_is_cancelled(cancel) != 0) return error.Cancelled;
    }

    try checkoutRef(repo.?, to_ref_c, to_checkout_path, cancellable);

    const from_gfile = c_libs.g_file_new_for_path(from_checkout_path.ptr);
    defer c_libs.g_object_unref(from_gfile);

    const to_gfile = c_libs.g_file_new_for_path(to_checkout_path.ptr);
    defer c_libs.g_object_unref(to_gfile);

    const modified_entries = c_libs.g_ptr_array_new();
    defer c_libs.g_ptr_array_unref(modified_entries);

    const removed_entries = c_libs.g_ptr_array_new();
    defer c_libs.g_ptr_array_unref(removed_entries);

    const added_entries = c_libs.g_ptr_array_new();
    defer c_libs.g_ptr_array_unref(added_entries);

    if (c_libs.ostree_diff_dirs(c_libs.OSTREE_DIFF_FLAGS_NONE, from_gfile, to_gfile, modified_entries, removed_entries, added_entries, cancellable, &gerror) == 0) return diff.DiffError.DiffFailed;

    var diff_entries = std.ArrayList(DiffEntry).init(allocator);
    errdefer {
        for (diff_entries.items) |entry| allocator.free(entry.path);
        diff_entries.deinit();
    }

    const to_prefix = @as([]const u8, to_checkout_path);
    const from_prefix = @as([]const u8, from_checkout_path);

    var index: usize = 0;
    while (index < added_entries.*.len) : (index += 1) {
        const gfile_ptr: *c_libs.GFile = @ptrCast(@alignCast(added_entries.*.pdata[index]));
        const raw_path = c_libs.g_file_get_path(gfile_ptr);
        defer c_libs.g_free(@ptrCast(raw_path));
        if (raw_path == null) continue;

        const file_path = std.mem.span(raw_path.?);
        const rel_path = if (std.mem.startsWith(u8, file_path, to_prefix)) file_path[to_prefix.len..] else file_path;
        diff_entries.append(.{ .path = allocator.dupe(u8, rel_path) catch return DiffError.AllocZPrintFailed, .kind = .added }) catch return DiffError.AllocZPrintFailed;
    }

    index = 0;
    while (index < removed_entries.*.len) : (index += 1) {
        const gfile_ptr: *c_libs.GFile = @ptrCast(@alignCast(removed_entries.*.pdata[index]));
        const raw_path = c_libs.g_file_get_path(gfile_ptr);
        defer c_libs.g_free(@ptrCast(raw_path));
        if (raw_path == null) continue;

        const file_path = std.mem.span(raw_path.?);
        const rel_path = if (std.mem.startsWith(u8, file_path, from_prefix)) file_path[from_prefix.len..] else file_path;
        diff_entries.append(.{ .path = allocator.dupe(u8, rel_path) catch return DiffError.AllocZPrintFailed, .kind = .removed }) catch return DiffError.AllocZPrintFailed;
    }

    index = 0;
    while (index < modified_entries.*.len) : (index += 1) {
        const diff_item: *c_libs.OstreeDiffItem = @ptrCast(@alignCast(modified_entries.*.pdata[index]));
        const raw_path = c_libs.g_file_get_path(diff_item.target);
        defer c_libs.g_free(@ptrCast(raw_path));
        if (raw_path == null) continue;

        const file_path = std.mem.span(raw_path.?);
        const rel_path = if (std.mem.startsWith(u8, file_path, to_prefix)) file_path[to_prefix.len..] else file_path;
        diff_entries.append(.{ .path = allocator.dupe(u8, rel_path) catch return DiffError.AllocZPrintFailed, .kind = .modified }) catch return DiffError.AllocZPrintFailed;
    }

    return diff_entries.toOwnedSlice() catch return DiffError.AllocZPrintFailed;
}

// Enriches a file diff with package attribution by mapping each changed path to its owning package
pub fn diffFilesAttributed(repo_path: []const u8, from_ref: []const u8, to_ref: []const u8, root_path: []const u8, db_path: []const u8, cancellable: ?*c_libs.GCancellable, allocator: std.mem.Allocator) DiffError![]AttributedDiffEntry {
    const raw_diff = diffFiles(repo_path, from_ref, to_ref, root_path, cancellable, allocator) catch return diff.DiffError.DiffFailed;
    defer {
        for (raw_diff) |entry| allocator.free(entry.path);
        allocator.free(raw_diff);
    }

    var file_pkg = std.StringHashMap([]const u8).init(allocator);
    defer packages.freeStringMap(&file_pkg, allocator);

    buildFilePkgMap(repo_path, to_ref, db_path, &file_pkg, cancellable, allocator) catch return diff.DiffError.DiffFailed;
    buildFilePkgMap(repo_path, from_ref, db_path, &file_pkg, cancellable, allocator) catch return diff.DiffError.DiffFailed;

    var result = std.ArrayList(AttributedDiffEntry).init(allocator);
    errdefer {
        for (result.items) |entry| {
            allocator.free(entry.path);
            allocator.free(entry.package_name);
        }
        result.deinit();
    }

    for (raw_diff) |entry| {
        const pkg = file_pkg.get(entry.path) orelse "";
        result.append(.{
            .path = allocator.dupe(u8, entry.path) catch return diff.DiffError.AllocZPrintFailed,
            .kind = entry.kind,
            .package_name = allocator.dupe(u8, pkg) catch return diff.DiffError.AllocZPrintFailed,
        }) catch return diff.DiffError.AllocZPrintFailed;
    }

    return result.toOwnedSlice() catch return DiffError.AllocZPrintFailed;
}

// ── Private helpers ───────────────────────────────────────────────────────────
fn checkoutRef(repo: *c_libs.OstreeRepo, ref_c: [:0]const u8, destination_path: [:0]const u8, cancellable: ?*c_libs.GCancellable) DiffError!void {
    var gerror: ?*c_libs.GError = null;
    defer if (gerror) |err| c_libs.g_error_free(err);

    var resolved_checksum: ?[*:0]u8 = null;
    defer if (resolved_checksum) |cs| c_libs.g_free(@ptrCast(cs));

    if (c_libs.ostree_repo_resolve_rev(repo, ref_c.ptr, 0, &resolved_checksum, &gerror) == 0) return diff.DiffError.DiffFailed;

    std.fs.makeDirAbsolute(destination_path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        error.FileNotFound => {
            const path_slice: []const u8 = destination_path;
            const rel = if (path_slice.len > 0 and path_slice[0] == '/') path_slice[1..] else path_slice;
            var root = std.fs.openDirAbsolute("/", .{}) catch return error.FileNotFound;
            defer root.close();
            root.makePath(rel) catch return error.FileNotFound;
        },
        else => return DiffError.DiffFailed,
    };

    var options = std.mem.zeroes(c_libs.OstreeRepoCheckoutAtOptions);
    options.mode = c_libs.OSTREE_REPO_CHECKOUT_MODE_NONE;
    options.overwrite_mode = c_libs.OSTREE_REPO_CHECKOUT_OVERWRITE_UNION_FILES;

    if (c_libs.ostree_repo_checkout_at(repo, &options, std.c.AT.FDCWD, destination_path.ptr, resolved_checksum, cancellable, &gerror) == 0) return DiffError.DiffFailed;
}

fn buildFilePkgMap(repo_path: []const u8, ref: []const u8, db_path: []const u8, out: *std.StringHashMap([]const u8), cancellable: ?*c_libs.GCancellable, allocator: std.mem.Allocator) DiffError!void {
    var gerror: ?*c_libs.GError = null;
    defer if (gerror) |err| c_libs.g_error_free(err);

    const repo_path_c = std.fmt.allocPrintZ(allocator, "{s}", .{repo_path}) catch return DiffError.AllocZPrintFailed;
    defer allocator.free(repo_path_c);

    const gfile = c_libs.g_file_new_for_path(repo_path_c.ptr);
    defer c_libs.g_object_unref(gfile);

    const repo = c_libs.ostree_repo_new(gfile);
    defer c_libs.g_object_unref(repo);

    if (c_libs.ostree_repo_open(repo, cancellable, &gerror) == 0) return;

    const body = (try packages.getRefBody(repo.?, ref, cancellable, allocator)) orelse return;
    defer allocator.free(body);

    var pkg_map = try packages.parsePackageBody(body, allocator);
    defer packages.freeStringMap(&pkg_map, allocator);

    var iter = pkg_map.iterator();
    while (iter.next()) |entry| {
        const pkg_name = entry.key_ptr.*;
        const pkg_checksum = entry.value_ptr.*;

        var file_map = data.readFiles(db_path, pkg_checksum, allocator) catch continue;
        defer data.freeFileMap(&file_map, allocator);

        var file_map_iter = file_map.iterator();
        while (file_map_iter.next()) |file_entry| {
            if (!out.contains(file_entry.key_ptr.*)) {
                out.put(
                    allocator.dupe(u8, file_entry.key_ptr.*) catch return diff.DiffError.AllocZPrintFailed,
                    allocator.dupe(u8, pkg_name) catch return diff.DiffError.AllocZPrintFailed,
                ) catch return diff.DiffError.AllocZPrintFailed;
            }
        }
    }
}
