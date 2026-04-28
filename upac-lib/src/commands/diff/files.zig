// ── Imports ─────────────────────────────────────────────────────────────────────
const std = @import("std");

const diff = @import("diff.zig");
const c_libs = diff.c_libs;
const data = diff.data;

const DiffEntry = diff.ffi.DiffEntry;
const AttributedDiffEntry = diff.ffi.AttributedDiffEntry;

const DiffError = diff.DiffError;

const packages = diff.packages;

const openRepo = diff.openRepo;

const check = diff.check;
const unwrap = diff.unwrap;

// Checks out two refs and compares their file trees using ostree_diff_dirs
pub fn diffFiles(repo_path_c: [*:0]u8, from_ref_c: [*:0]u8, to_ref_c: [*:0]u8, root_path_c: [*:0]u8, gerror: *[*c]c_libs.GError, cancellable: [*c]c_libs.GCancellable, allocator: std.mem.Allocator) DiffError![]DiffEntry {
    var from_checkout_buf: [256]u8 = undefined;
    var to_checkout_buf: [256]u8 = undefined;
    const timestamp = std.time.milliTimestamp();

    const gfile = c_libs.g_file_new_for_path(repo_path_c);
    defer c_libs.g_object_unref(gfile);

    const repo = try openRepo(repo_path_c, cancellable, &gerror);
    defer c_libs.g_object_unref(repo);

    const from_checkout_temp_dir_name = try check(std.fmt.bufPrint(&from_checkout_buf, "diff-from-{d}", .{timestamp}), DiffError.AllocZPrintFailed);

    const from_checkout_path_c = try check(std.fs.path.joinZ(allocator, &.{ std.mem.span(root_path_c), from_checkout_temp_dir_name }), DiffError.AllocZPrintFailed);
    defer allocator.free(from_checkout_path_c);
    defer std.fs.deleteTreeAbsolute(from_checkout_path_c) catch {};

    try checkoutRef(repo, from_ref_c, from_checkout_path_c, cancellable);

    const from_gfile = c_libs.g_file_new_for_path(from_checkout_path_c);
    defer c_libs.g_object_unref(from_gfile);

    if (cancellable) |cancel| if (c_libs.g_cancellable_is_cancelled(cancel) != 0) return error.Cancelled;

    const to_checkout_temp_dir_name = try check(std.fmt.bufPrint(&to_checkout_buf, "diff-to-{d}", .{timestamp}), DiffError.AllocZPrintFailed);

    const to_checkout_path_c = try check(std.fs.path.joinZ(allocator, &.{ std.mem.span(root_path_c), to_checkout_temp_dir_name }), DiffError.AllocZPrintFailed);
    defer allocator.free(to_checkout_path_c);
    defer std.fs.deleteTreeAbsolute(to_checkout_path_c) catch {};

    try checkoutRef(repo, to_ref_c, to_checkout_path_c, cancellable);

    const to_gfile = c_libs.g_file_new_for_path(to_checkout_path_c);
    defer c_libs.g_object_unref(to_gfile);

    const modified_entries = c_libs.g_ptr_array_new();
    defer c_libs.g_ptr_array_unref(modified_entries);

    const removed_entries = c_libs.g_ptr_array_new();
    defer c_libs.g_ptr_array_unref(removed_entries);

    const added_entries = c_libs.g_ptr_array_new();
    defer c_libs.g_ptr_array_unref(added_entries);

    if (c_libs.ostree_diff_dirs(c_libs.OSTREE_DIFF_FLAGS_NONE, from_gfile, to_gfile, modified_entries, removed_entries, added_entries, cancellable, &gerror) == 0) {
        if (gerror) |err| {
            if (err.domain == c_libs.g_io_error_quark() and err.code == c_libs.G_IO_ERROR_CANCELLED) {
                return error.Cancelled;
            }
        }
        return error.DiffFailed;
    }

    var diff_entries = std.ArrayList(DiffEntry).empty;
    errdefer {
        for (diff_entries.items) |entry| allocator.free(entry.path);
        diff_entries.deinit(allocator);
    }

    const to_prefix = @as([]const u8, to_checkout_path_c);
    const from_prefix = @as([]const u8, from_checkout_path_c);

    try collectEntries(added_entries, to_prefix, .added, false, &diff_entries, allocator);
    try collectEntries(removed_entries, from_prefix, .removed, false, &diff_entries, allocator);
    try collectEntries(modified_entries, to_prefix, .modified, true, &diff_entries, allocator);

    return try check(diff_entries.toOwnedSlice(allocator), DiffError.AllocZPrintFailed);
}

// Enriches a file diff with package attribution by mapping each changed path to its owning package
pub fn diffFilesAttributed(repo_path_c: [*:0]u8, from_ref_c: [*:0]u8, to_ref_c: [*:0]u8, root_path: [*:0]u8, db_path: []const u8, cancellable: [*c]c_libs.GCancellable, allocator: std.mem.Allocator) DiffError![]AttributedDiffEntry {
    const raw_diff = diffFiles(repo_path_c, from_ref_c, to_ref_c, root_path, cancellable, allocator) catch return error.DiffFailed;
    defer {
        for (raw_diff) |entry| allocator.free(entry.path);
        allocator.free(raw_diff);
    }

    var file_pkg = std.StringHashMap([]const u8).init(allocator);
    defer packages.freeStringMap(&file_pkg, allocator);

    try check(buildFilePkgMap(repo_path_c, to_ref_c, db_path, &file_pkg, cancellable, allocator), DiffError.DiffFailed);

    try check(buildFilePkgMap(repo_path_c, from_ref_c, db_path, &file_pkg, cancellable, allocator), DiffError.DiffFailed);

    var result = std.ArrayList(AttributedDiffEntry).empty;
    errdefer {
        for (result.items) |entry| {
            allocator.free(entry.path);
            allocator.free(entry.package_name);
        }
        result.deinit(allocator);
    }

    for (raw_diff) |entry| {
        const pkg = file_pkg.get(entry.path) orelse "";
        try check(result.append(allocator, .{
            .path = try check(allocator.dupe(u8, entry.path), DiffError.AllocZPrintFailed),
            .kind = entry.kind,
            .package_name = try check(allocator.dupe(u8, pkg), DiffError.AllocZPrintFailed),
        }), DiffError.AllocZPrintFailed);
    }

    return try check(result.toOwnedSlice(allocator), DiffError.AllocZPrintFailed);
}

// ── Private helpers ───────────────────────────────────────────────────────────
fn checkoutRef(repo: *c_libs.OstreeRepo, ref_c: [*:0]u8, destination_path: [*:0]u8, cancellable: [*c]c_libs.GCancellable, gerror: *[*c]c_libs.GError) DiffError!void {
    var resolved_checksum: [*c]u8 = null;
    defer if (resolved_checksum != null) c_libs.g_free(resolved_checksum);

    if (c_libs.ostree_repo_resolve_rev(repo, ref_c, 0, &resolved_checksum, &gerror) == 0) return error.DiffFailed;

    std.fs.makeDirAbsolute(std.mem.span(destination_path)) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        error.FileNotFound => {
            const path_slice: []const u8 = std.mem.span(destination_path);
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

    if (c_libs.ostree_repo_checkout_at(repo, &options, std.c.AT.FDCWD, destination_path, resolved_checksum, cancellable, &gerror) == 0) return DiffError.DiffFailed;
}

fn buildFilePkgMap(repo_path_c: [*:0]u8, ref_c: [*:0]u8, db_path: []const u8, out: *std.StringHashMap([]const u8), cancellable: [*c]c_libs.GCancellable, gerror: *[*c]c_libs.GError, allocator: std.mem.Allocator) DiffError!void {
    const repo = try openRepo(repo_path_c, cancellable, &gerror);
    defer c_libs.g_object_unref(repo);

    const body = (try packages.getRefBody(repo, ref_c, cancellable, allocator)) orelse return;
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
            if (!out.contains(file_entry.key_ptr.*)) try check(out.put(try check(allocator.dupe(u8, file_entry.key_ptr.*), DiffError.AllocZPrintFailed), try check(allocator.dupe(u8, pkg_name), DiffError.AllocZPrintFailed)), DiffError.AllocZPrintFailed);
        }
    }
}

fn collectEntries(entries_ptr_array: *c_libs.GPtrArray, prefix: []const u8, kind: diff.ffi.DiffKind, use_target: bool, result: *std.ArrayList(diff.ffi.DiffEntry), allocator: std.mem.Allocator) DiffError!void {
    var index: usize = 0;
    while (index < entries_ptr_array.*.len) : (index += 1) {
        const raw_path = if (use_target) blk: {
            const item: *c_libs.OstreeDiffItem = @ptrCast(@alignCast(entries_ptr_array.*.pdata[index]));
            break :blk c_libs.g_file_get_path(item.target);
        } else blk: {
            const gfile_ptr: *c_libs.GFile = @ptrCast(@alignCast(entries_ptr_array.*.pdata[index]));
            break :blk c_libs.g_file_get_path(gfile_ptr);
        };
        defer c_libs.g_free(@ptrCast(raw_path));
        if (raw_path == null) continue;

        const file_path = std.mem.span(raw_path);
        const rel_path = if (std.mem.startsWith(u8, file_path, prefix)) file_path[prefix.len..] else file_path;
        const rel_path_dupe = try check(allocator.dupe(u8, rel_path), DiffError.AllocZPrintFailed);

        try check(result.append(allocator, .{ .path = rel_path_dupe, .kind = kind }), DiffError.AllocZPrintFailed);
    }
}
