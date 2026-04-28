// ── Imports ─────────────────────────────────────────────────────────────────────
const std = @import("std");

const diff = @import("diff.zig");
const c_libs = diff.c_libs;

const DiffError = diff.DiffError;

const PackageDiffEntry = diff.ffi.PackageDiffEntry;

const openRepo = diff.openRepo;

const check = diff.check;
const unwrap = diff.unwrap;

// Compares the package sets of two commits and returns a list of added, removed, and updated packages
pub fn diffPackages(repo_path_c: [*:0]u8, from_ref_c: [*:0]u8, to_ref_c: [*:0]u8, cancellable: [*c]c_libs.GCancellable, gerror: *[*c]c_libs.GError, allocator: std.mem.Allocator) ![]PackageDiffEntry {
    const repo = try openRepo(repo_path_c, cancellable, &gerror);
    defer c_libs.g_object_unref(repo);

    const from_body = try getRefBody(repo, from_ref_c, cancellable, allocator);
    defer if (from_body) |body| allocator.free(body);

    const to_body = try getRefBody(repo, to_ref_c, cancellable, allocator);
    defer if (to_body) |body| allocator.free(body);

    var file_map_from = try parsePackageBody(from_body orelse "", allocator);
    defer freeStringMap(&file_map_from, allocator);

    var fileMap_to = try parsePackageBody(to_body orelse "", allocator);
    defer freeStringMap(&fileMap_to, allocator);

    var entries = std.ArrayList(PackageDiffEntry).empty;
    errdefer {
        for (entries.items) |entry| allocator.free(entry.name);
        entries.deinit(allocator);
    }

    var files_map_to_iter = fileMap_to.iterator();
    while (files_map_to_iter.next()) |entry| {
        if (file_map_from.get(entry.key_ptr.*)) |from_checksum| {
            if (!std.mem.eql(u8, from_checksum, entry.value_ptr.*)) {
                const entry_ley_dupe = try check(allocator.dupe(u8, entry.key_ptr.*), DiffError.AllocZPrintFailed);
                try check(entries.append(allocator, .{ .name = entry_ley_dupe, .kind = .updated }), DiffError.AllocZPrintFailed);
            }
        } else {
            const entry_ley_dupe = try check(allocator.dupe(u8, entry.key_ptr.*), DiffError.AllocZPrintFailed);
            try check(entries.append(allocator, .{ .name = entry_ley_dupe, .kind = .added }), DiffError.AllocZPrintFailed);
        }
    }

    var file_map_from_iter = file_map_from.iterator();
    while (file_map_from_iter.next()) |entry| {
        if (!fileMap_to.contains(entry.key_ptr.*)) {
            const entry_key_dupe = try check(allocator.dupe(u8, entry.key_ptr.*), DiffError.AllocZPrintFailed);
            try check(entries.append(allocator, .{ .name = entry_key_dupe, .kind = .removed }), DiffError.AllocZPrintFailed);
        }
    }

    return try check(entries.toOwnedSlice(allocator), DiffError.AllocZPrintFailed);
}

// ── Private helpers ───────────────────────────────────────────────────────────
pub fn getRefBody(repo: *c_libs.OstreeRepo, ostree_ref_c: [*:0]u8, gerror: *[*c]c_libs.GError, allocator: std.mem.Allocator) DiffError!?[]const u8 {
    var checksum: [*c]u8 = null;
    defer if (checksum) |checksum_unwraped| c_libs.g_free(@ptrCast(checksum_unwraped));

    if (c_libs.ostree_repo_resolve_rev(repo, ostree_ref_c, 1, &checksum, &gerror) == 0 or checksum == null) return null;

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
        map.put(allocator.dupe(u8, name) catch return DiffError.AllocZPrintFailed, allocator.dupe(u8, checksum) catch return DiffError.AllocZPrintFailed) catch return DiffError.AllocZPrintFailed;
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
