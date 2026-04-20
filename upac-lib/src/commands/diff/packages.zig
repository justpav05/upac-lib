// ── Imports ─────────────────────────────────────────────────────────────────────
const std = @import("std");

const diff = @import("diff.zig");
const c_libs = diff.c_libs;
const data = diff.data;

const PackageDiffEntry = diff.ffi.PackageDiffEntry;
const CommitEntry = diff.ffi.CommitEntry;

// Compares the package sets of two commits and returns a list of added, removed, and updated packages
pub fn diffPackages(repo_path: []const u8, from_ref: []const u8, to_ref: []const u8, allocator: std.mem.Allocator) ![]PackageDiffEntry {
    var gerror: ?*c_libs.GError = null;
    defer if (gerror) |err| c_libs.g_error_free(err);

    const repo_path_c = try std.fmt.allocPrintZ(allocator, "{s}", .{repo_path});
    defer allocator.free(repo_path_c);

    const gfile = c_libs.g_file_new_for_path(repo_path_c.ptr);
    defer c_libs.g_object_unref(gfile);

    const repo = c_libs.ostree_repo_new(gfile);
    defer c_libs.g_object_unref(repo);

    if (c_libs.ostree_repo_open(repo, null, &gerror) == 0) return diff.DiffError.RepoOpenFailed;

    const from_body = try getRefBody(repo.?, from_ref, allocator);
    defer if (from_body) |body| allocator.free(body);

    const to_body = try getRefBody(repo.?, to_ref, allocator);
    defer if (to_body) |body| allocator.free(body);

    var file_map_from = try parsePackageBody(from_body orelse "", allocator);
    defer freeStringMap(&file_map_from, allocator);

    var fileMap_to = try parsePackageBody(to_body orelse "", allocator);
    defer freeStringMap(&fileMap_to, allocator);

    var entries = std.ArrayList(PackageDiffEntry).init(allocator);
    errdefer {
        for (entries.items) |entry| allocator.free(entry.name);
        entries.deinit();
    }

    var files_map_to_iter = fileMap_to.iterator();
    while (files_map_to_iter.next()) |entry| {
        if (file_map_from.get(entry.key_ptr.*)) |from_checksum| {
            if (!std.mem.eql(u8, from_checksum, entry.value_ptr.*))
                try entries.append(.{ .name = try allocator.dupe(u8, entry.key_ptr.*), .kind = .updated });
        } else {
            try entries.append(.{ .name = try allocator.dupe(u8, entry.key_ptr.*), .kind = .added });
        }
    }

    var file_map_from_iter = file_map_from.iterator();
    while (file_map_from_iter.next()) |entry| {
        if (!fileMap_to.contains(entry.key_ptr.*))
            try entries.append(.{ .name = try allocator.dupe(u8, entry.key_ptr.*), .kind = .removed });
    }

    return entries.toOwnedSlice();
}

// Returns the installed package metadata list from the latest commit on a branch
pub fn listPackages(repo_path: []const u8, branch: []const u8, db_path: []const u8, allocator: std.mem.Allocator) ![]diff.ffi.PackageMeta {
    var gerror: ?*c_libs.GError = null;
    defer if (gerror) |err| c_libs.g_error_free(err);

    const repo_path_c = try std.fmt.allocPrintZ(allocator, "{s}", .{repo_path});
    defer allocator.free(repo_path_c);

    const branch_c = try std.fmt.allocPrintZ(allocator, "{s}", .{branch});
    defer allocator.free(branch_c);

    const gfile = c_libs.g_file_new_for_path(repo_path_c.ptr);
    defer c_libs.g_object_unref(gfile);

    const repo = c_libs.ostree_repo_new(gfile);
    defer c_libs.g_object_unref(repo);

    if (c_libs.ostree_repo_open(repo, null, &gerror) == 0) return diff.DiffError.RepoOpenFailed;

    var head_checksum: ?[*:0]u8 = null;
    if (c_libs.ostree_repo_resolve_rev(repo, branch_c.ptr, 1, &head_checksum, null) == 0 or head_checksum == null)
        return &.{};
    defer c_libs.g_free(@ptrCast(head_checksum));

    const body = (try getRefBody(repo.?, branch, allocator)) orelse return &.{};
    defer allocator.free(body);

    var package_map = try parsePackageBody(body, allocator);
    defer freeStringMap(&package_map, allocator);

    var result_paackage_metas = std.ArrayList(diff.ffi.PackageMeta).init(allocator);
    errdefer {
        for (result_paackage_metas.items) |item| data.freePackageMeta(item, allocator);
        result_paackage_metas.deinit();
    }

    var package_map_iter = package_map.iterator();
    while (package_map_iter.next()) |entry| {
        const package_meta = data.readMeta(db_path, entry.value_ptr.*, allocator) catch continue;
        try result_paackage_metas.append(package_meta);
    }

    return result_paackage_metas.toOwnedSlice();
}

// Walks the commit chain of a branch and returns all commits as a slice
pub fn listCommits(repo_path: []const u8, branch: []const u8, allocator: std.mem.Allocator) ![]CommitEntry {
    var gerror: ?*c_libs.GError = null;
    defer if (gerror) |err| c_libs.g_error_free(err);

    const repo_path_c = try std.fmt.allocPrintZ(allocator, "{s}", .{repo_path});
    defer allocator.free(repo_path_c);

    const branch_c = try std.fmt.allocPrintZ(allocator, "{s}", .{branch});
    defer allocator.free(branch_c);

    const gfile = c_libs.g_file_new_for_path(repo_path_c.ptr);
    defer c_libs.g_object_unref(gfile);

    const repo = c_libs.ostree_repo_new(gfile);
    defer c_libs.g_object_unref(repo);

    if (c_libs.ostree_repo_open(repo, null, &gerror) == 0) return diff.DiffError.RepoOpenFailed;

    var entries = std.ArrayList(CommitEntry).init(allocator);
    errdefer {
        for (entries.items) |entry| {
            allocator.free(entry.checksum);
            allocator.free(entry.subject);
        }
        entries.deinit();
    }

    var current_checksum: ?[*:0]u8 = null;
    if (c_libs.ostree_repo_resolve_rev(repo, branch_c.ptr, 0, &current_checksum, &gerror) == 0) return entries.toOwnedSlice();

    var checksum = current_checksum;
    while (checksum) |current_cs| {
        var commit_variant: ?*c_libs.GVariant = null;

        if (c_libs.ostree_repo_load_variant(repo, c_libs.OSTREE_OBJECT_TYPE_COMMIT, current_cs, &commit_variant, &gerror) == 0) break;

        defer if (commit_variant) |variant| c_libs.g_variant_unref(variant);

        var subject_variant: ?*c_libs.GVariant = null;
        subject_variant = c_libs.g_variant_get_child_value(commit_variant, 3);
        defer if (subject_variant) |variant| c_libs.g_variant_unref(variant);

        var subject_len: usize = 0;
        const subject_ptr = c_libs.g_variant_get_string(subject_variant, &subject_len);

        try entries.append(.{
            .checksum = try allocator.dupe(u8, std.mem.span(current_cs)),
            .subject = try allocator.dupe(u8, subject_ptr[0..subject_len]),
        });

        const parent_checksum = c_libs.ostree_commit_get_parent(commit_variant);
        if (current_checksum != null and current_checksum != checksum)
            c_libs.g_free(@ptrCast(checksum));
        checksum = parent_checksum;
    }

    if (current_checksum) |cs| c_libs.g_free(@ptrCast(cs));
    return entries.toOwnedSlice();
}

// ── Private helpers ───────────────────────────────────────────────────────────
pub fn getRefBody(repo: *c_libs.OstreeRepo, ostree_ref: []const u8, allocator: std.mem.Allocator) !?[]const u8 {
    var gerror: ?*c_libs.GError = null;
    defer if (gerror) |err| c_libs.g_error_free(err);

    const ostree_ref_c = try std.fmt.allocPrintZ(allocator, "{s}", .{ostree_ref});
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

    return try allocator.dupe(u8, body_ptr[0..body_len]);
}

pub fn parsePackageBody(body: []const u8, allocator: std.mem.Allocator) !std.StringHashMap([]const u8) {
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
        try map.put(try allocator.dupe(u8, name), try allocator.dupe(u8, checksum));
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
