const diff = @import("diff.zig");
const std = diff.std;
const c_libs = diff.c_libs;
const data = diff.data;
const DiffError = diff.DiffError;
const CDiffKind = diff.ffi.CDiffKind;

pub const RawDiffEntry = struct {
    path: []const u8,
    kind: CDiffKind,
};

pub fn getRefBody(repo: *c_libs.OstreeRepo, ref: [*:0]const u8, gerror: *?*c_libs.GError, allocator: std.mem.Allocator) DiffError!?[]const u8 {
    var commit_checksum: [*c]u8 = null;
    defer if (commit_checksum != null) c_libs.g_free(commit_checksum);

    if (c_libs.ostree_repo_resolve_rev(repo, ref, 1, &commit_checksum, gerror) == 0 or commit_checksum == null) return null;

    var commit_variant: ?*c_libs.GVariant = null;
    defer if (commit_variant) |varinat| c_libs.g_variant_unref(varinat);

    if (c_libs.ostree_repo_load_variant(repo, c_libs.OSTREE_OBJECT_TYPE_COMMIT, commit_checksum, &commit_variant, gerror) == 0) return null;

    const body_variant = c_libs.g_variant_get_child_value(commit_variant, 4);
    defer if (body_variant) |v| c_libs.g_variant_unref(v);

    var len: usize = 0;
    const ptr = c_libs.g_variant_get_string(body_variant, &len);
    return allocator.dupe(u8, ptr[0..len]) catch return DiffError.AllocFailed;
}

pub fn parsePackageBody(body: []const u8, allocator: std.mem.Allocator) DiffError!std.StringHashMap([]const u8) {
    var map = std.StringHashMap([]const u8).init(allocator);
    errdefer freeStringMap(&map, allocator);

    var iter = std.mem.splitScalar(u8, body, '\n');
    while (iter.next()) |line| {
        const trimmed_line = std.mem.trim(u8, line, " \t\r");
        if (trimmed_line.len == 0) continue;
        const separator_index = std.mem.indexOfScalar(u8, trimmed_line, ' ') orelse continue;
        const name = trimmed_line[0..separator_index];
        const checksum = std.mem.trim(u8, trimmed_line[separator_index + 1 ..], " \t");
        if (name.len == 0 or checksum.len == 0) continue;
        const key_dupe = allocator.dupe(u8, name) catch return DiffError.AllocFailed;
        const value_dupe = allocator.dupe(u8, checksum) catch return DiffError.AllocFailed;
        map.put(key_dupe, value_dupe) catch return DiffError.AllocFailed;
    }
    return map;
}

pub fn freeStringMap(map: *std.StringHashMap([]const u8), allocator: std.mem.Allocator) void {
    var iter = map.iterator();
    while (iter.next()) |entry| {
        allocator.free(entry.key_ptr.*);
        allocator.free(entry.value_ptr.*);
    }
    map.deinit();
}

pub fn resolveCommitRoot(repo: *c_libs.OstreeRepo, ref: [*:0]const u8, cancellable: ?*c_libs.GCancellable, gerror: *?*c_libs.GError) DiffError!*c_libs.GFile {
    var commit_checksum: [*c]u8 = null;
    defer if (commit_checksum != null) c_libs.g_free(commit_checksum);

    if (c_libs.ostree_repo_resolve_rev(repo, ref, 0, &commit_checksum, gerror) == 0 or commit_checksum == null)
        return DiffError.CommitNotFound;

    var root_gfile: ?*c_libs.GFile = null;
    if (c_libs.ostree_repo_read_commit(repo, commit_checksum, &root_gfile, null, cancellable, gerror) == 0)
        return DiffError.CommitNotFound;

    return root_gfile orelse DiffError.CommitNotFound;
}

pub fn buildFilePkgMap(repo: *c_libs.OstreeRepo, ref: [*:0]const u8, db_path: []const u8, out: *std.StringHashMap([]const u8), gerror: *?*c_libs.GError, allocator: std.mem.Allocator) DiffError!void {
    const body = (try getRefBody(repo, ref, gerror, allocator)) orelse return;
    defer allocator.free(body);

    var pkg_map = try parsePackageBody(body, allocator);
    defer freeStringMap(&pkg_map, allocator);

    var iter = pkg_map.iterator();
    while (iter.next()) |entry| {
        var file_map = data.readFiles(db_path, entry.value_ptr.*, allocator) catch continue;
        defer data.freeFileMap(&file_map, allocator);

        var file_iter = file_map.iterator();
        while (file_iter.next()) |fe| {
            if (out.contains(fe.key_ptr.*)) continue;
            const key_dupe = allocator.dupe(u8, fe.key_ptr.*) catch return DiffError.AllocFailed;
            const value_dupe = allocator.dupe(u8, entry.key_ptr.*) catch return DiffError.AllocFailed;
            out.put(key_dupe, value_dupe) catch return DiffError.AllocFailed;
        }
    }
}

pub fn collectEntries(arr: *c_libs.GPtrArray, root_gfile: *c_libs.GFile, kind: CDiffKind, use_target: bool, result: *std.ArrayList(RawDiffEntry), allocator: std.mem.Allocator) DiffError!void {
    var index: usize = 0;
    while (index < arr.*.len) : (index += 1) {
        const item_gfile: *c_libs.GFile = if (use_target) blk: {
            const diff_item: *c_libs.OstreeDiffItem = @ptrCast(@alignCast(arr.*.pdata[index]));
            break :blk @ptrCast(diff_item.target);
        } else blk: {
            break :blk @ptrCast(@alignCast(arr.*.pdata[index]));
        };

        const relative_path = c_libs.g_file_get_relative_path(@ptrCast(root_gfile), item_gfile);
        defer if (relative_path != null) c_libs.g_free(@ptrCast(relative_path));
        if (relative_path == null) continue;

        const path_dupe = allocator.dupe(u8, std.mem.span(relative_path)) catch return DiffError.AllocFailed;
        result.append(allocator, .{ .path = path_dupe, .kind = kind }) catch return DiffError.AllocFailed;
    }
}
