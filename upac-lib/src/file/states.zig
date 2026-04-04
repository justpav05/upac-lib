const std = @import("std");
const file = @import("file.zig");
const c_libs = file.c_libs;

const FileFSM = file.FileFSM;
const FileFSMError = file.FileFSMError;

// ── Public entry point ───────────────────────────────────────────────────────
pub fn stateStart(machine: *FileFSM) !void {
    try machine.enter(.start);

    return stateValidation(machine);
}

// ── States ───────────────────────────────────────────────────────────────────
fn stateValidation(machine: *FileFSM) !void {
    try machine.enter(.validation);

    machine.temp_file_checksum = computeOstreeChecksum(
        machine.data.temp_path,
        machine.allocator,
    ) catch {
        if (machine.exhausted()) return FileFSMError.MaxRetriesExceeded;
        machine.retries += 1;
        return stateValidation(machine);
    };

    machine.resetRetries();

    return stateCopying(machine);
}

fn stateCopying(machine: *FileFSM) !void {
    try machine.enter(.copying);

    const ostree_checksum = writeFileToRepo(
        machine.data.repo,
        machine.data.temp_path,
        machine.allocator,
    ) catch {
        if (machine.exhausted()) return FileFSMError.MaxRetriesExceeded;
        machine.retries += 1;
        return stateCopying(machine);
    };

    const temp_checksum = machine.temp_file_checksum orelse {
        machine.allocator.free(ostree_checksum);
        return FileFSMError.ChecksumComputeFailed;
    };

    if (!std.mem.eql(u8, temp_checksum, ostree_checksum)) {
        machine.allocator.free(ostree_checksum);
        return FileFSMError.ChecksumMismatch;
    }

    machine.ostree_file_checksum = ostree_checksum;
    machine.resetRetries();

    return stateGetRelativePath(machine);
}

fn stateGetRelativePath(machine: *FileFSM) !void {
    try machine.enter(.get_relative_path);

    const temp_path = machine.data.temp_path;
    const relative_path = machine.data.relative_path;

    if (relative_path.len > temp_path.len) return FileFSMError.RelativePathMismatch;

    const sep_pos = temp_path.len - relative_path.len;

    if (!std.mem.eql(u8, temp_path[sep_pos..], relative_path))
        return FileFSMError.RelativePathMismatch;

    if (sep_pos > 0 and temp_path[sep_pos - 1] != '/')
        return FileFSMError.RelativePathMismatch;

    return stateAddToMtree(machine);
}

fn stateAddToMtree(machine: *FileFSM) !void {
    try machine.enter(.add_to_mtree);

    const ostree_checksum = machine.ostree_file_checksum orelse
        return FileFSMError.ChecksumComputeFailed;

    try insertIntoMtree(
        machine.data.mtree,
        machine.data.relative_path,
        ostree_checksum,
        machine.allocator,
    ) catch {
        if (machine.exhausted()) return FileFSMError.MaxRetriesExceeded;
        machine.retries += 1;
        return stateAddToMtree(machine);
    };

    return stateDone(machine);
}

fn stateDone(machine: *FileFSM) !void {
    try machine.enter(.done);
}

// ── Private helpers ──────────────────────────────────────────────────────────
fn computeOstreeChecksum(path: [:0]const u8, allocator: std.mem.Allocator) ![]const u8 {
    var gerror: ?*c_libs.GError = null;

    const gfile = c_libs.g_file_new_for_path(path.ptr);
    defer c_libs.g_object_unref(@ptrCast(gfile));

    var checksum: ?[*:0]u8 = null;
    if (c_libs.ostree_checksum_file(gfile, c_libs.OSTREE_OBJECT_TYPE_FILE, &checksum, null, &gerror) == 0) {
        if (gerror) |err| c_libs.g_error_free(err);

        return FileFSMError.ChecksumComputeFailed;
    }
    defer c_libs.g_free(@ptrCast(checksum));

    return allocator.dupe(u8, std.mem.span(checksum.?));
}

fn writeFileToRepo(repo: *c_libs.OstreeRepo, path: [:0]const u8, allocator: std.mem.Allocator) ![]const u8 {
    var gerror: ?*c_libs.GError = null;

    const gfile = c_libs.g_file_new_for_path(path.ptr);
    defer c_libs.g_object_unref(@ptrCast(gfile));

    const file_info = c_libs.g_file_query_info(gfile, "standard::*,unix::*", c_libs.G_FILE_QUERY_INFO_NOFOLLOW_SYMLINKS, null, &gerror) orelse {
        if (gerror) |err| c_libs.g_error_free(err);
        return FileFSMError.FileNotFound;
    };
    defer c_libs.g_object_unref(@ptrCast(file_info));

    const raw_file_input = c_libs.g_file_read(gfile, null, &gerror) orelse {
        if (gerror) |err| c_libs.g_error_free(err);
        return FileFSMError.RepoWriteFailed;
    };
    defer c_libs.g_object_unref(@ptrCast(raw_file_input));

    var ostree_content_stream: ?*c_libs.GInputStream = null;
    var ostree_content_length: c_libs.guint64 = 0;
    if (c_libs.ostree_raw_file_to_content_stream(
        @ptrCast(raw_file_input),
        file_info,
        null,
        &ostree_content_stream,
        &ostree_content_length,
        null,
        &gerror,
    ) == 0) {
        if (gerror) |err| c_libs.g_error_free(err);
        return FileFSMError.RepoWriteFailed;
    }
    defer c_libs.g_object_unref(@ptrCast(ostree_content_stream));

    var checksum_bin: ?[*]c_libs.guchar = null;
    if (c_libs.ostree_repo_write_content(repo, null, ostree_content_stream, ostree_content_length, &checksum_bin, null, &gerror) == 0) {
        if (gerror) |err| c_libs.g_error_free(err);
        return FileFSMError.RepoWriteFailed;
    }
    defer c_libs.g_free(@ptrCast(checksum_bin));

    var hex_buf: [65]u8 = undefined;
    c_libs.ostree_checksum_inplace_from_bytes(checksum_bin.?, &hex_buf);

    return allocator.dupe(u8, hex_buf[0..64]);
}

fn insertIntoMtree(root_mtree: *c_libs.OstreeMutableTree, relative_path: []const u8, checksum: []const u8, allocator: std.mem.Allocator) !void {
    var gerror: ?*c_libs.GError = null;

    var path_components = std.ArrayList([]const u8).init(allocator);
    defer path_components.deinit();

    var relative_path_iter = std.mem.splitScalar(u8, relative_path, '/');
    while (relative_path_iter.next()) |path_part| {
        if (path_part.len > 0) try path_components.append(path_part);
    }
    if (path_components.items.len == 0) return FileFSMError.MtreeEnsureDirFailed;

    const filename = path_components.items[path_components.items.len - 1];
    const dir_parts = path_components.items[0 .. path_components.items.len - 1];

    var curren_mtree = root_mtree;
    for (dir_parts) |dir_name| {
        const dir_path_c = try allocator.dupeZ(u8, dir_name);
        defer allocator.free(dir_path_c);

        var subdir: ?*c_libs.OstreeMutableTree = null;
        if (c_libs.ostree_mutable_tree_ensure_dir(curren_mtree, dir_path_c.ptr, &subdir, &gerror) == 0) {
            if (gerror) |err| c_libs.g_error_free(err);

            return FileFSMError.MtreeEnsureDirFailed;
        }
        curren_mtree = subdir.?;
    }

    const filename_c = try allocator.dupeZ(u8, filename);
    defer allocator.free(filename_c);
    const checksums_c = try allocator.dupeZ(u8, checksum);
    defer allocator.free(checksums_c);

    _ = c_libs.g_hash_table_insert(
        c_libs.ostree_mutable_tree_get_files(curren_mtree),
        @ptrCast(c_libs.g_strdup(filename_c.ptr)),
        @ptrCast(c_libs.g_strdup(checksums_c.ptr)),
    );
}
