const std = @import("std");

const file = @import("file.zig");
const c_libs = file.c_libs;

const FileFSM = file.FileFSM;
const FileFSMError = file.FileFSMError;

// ── Entry point ───────────────────────────────────────────────────────────────
pub fn stateStart(machine: *FileFSM) !void {
    try machine.enter(.start);
    return stateChecksum(machine);
}

// ── States ────────────────────────────────────────────────────────────────────
fn stateChecksum(machine: *FileFSM) !void {
    try machine.enter(.checksum);

    var gerror: ?*c_libs.GError = null;

    const gfile = c_libs.g_file_new_for_path(machine.data.temp_path.ptr);
    defer c_libs.g_object_unref(@ptrCast(gfile));

    var raw_checksum: ?[*:0]u8 = null;
    if (c_libs.ostree_checksum_file(gfile, c_libs.OSTREE_OBJECT_TYPE_FILE, &raw_checksum, null, &gerror) == 0) {
        if (gerror) |err| c_libs.g_error_free(err);
        if (machine.exhausted()) return FileFSMError.ChecksumFailed;
        machine.retries += 1;
        return stateChecksum(machine);
    }
    defer c_libs.g_free(@ptrCast(raw_checksum));

    machine.file_checksum = try machine.allocator.dupe(u8, std.mem.span(raw_checksum.?));

    machine.resetRetries();
    return stateWriteObject(machine);
}

fn stateWriteObject(machine: *FileFSM) !void {
    try machine.enter(.write_object);

    var gerror: ?*c_libs.GError = null;

    const gfile = c_libs.g_file_new_for_path(machine.data.temp_path.ptr);
    defer c_libs.g_object_unref(@ptrCast(gfile));

    const file_info = c_libs.g_file_query_info(gfile, "standard::*,unix::*", c_libs.G_FILE_QUERY_INFO_NOFOLLOW_SYMLINKS, null, &gerror) orelse {
        if (gerror) |err| c_libs.g_error_free(err);
        return FileFSMError.FileNotFound;
    };
    defer c_libs.g_object_unref(@ptrCast(file_info));

    const raw_file_stream = c_libs.g_file_read(gfile, null, &gerror) orelse {
        if (gerror) |err| c_libs.g_error_free(err);
        if (machine.exhausted()) return FileFSMError.RepoWriteFailed;
        machine.retries += 1;
        return stateWriteObject(machine);
    };
    defer c_libs.g_object_unref(@ptrCast(raw_file_stream));

    var file_content_stream: ?*c_libs.GInputStream = null;
    var file_content_length: c_libs.guint64 = 0;
    if (c_libs.ostree_raw_file_to_content_stream(@ptrCast(raw_file_stream), file_info, null, &file_content_stream, &file_content_length, null, &gerror) == 0) {
        if (gerror) |err| c_libs.g_error_free(err);
        if (machine.exhausted()) return FileFSMError.RepoWriteFailed;
        machine.retries += 1;
        return stateWriteObject(machine);
    }
    defer c_libs.g_object_unref(@ptrCast(file_content_stream));

    const expected_checksum = machine.file_checksum orelse
        return FileFSMError.ChecksumFailed;
    const expected_c = try machine.allocator.dupeZ(u8, expected_checksum);
    defer machine.allocator.free(expected_c);

    var object_exists: c_libs.gboolean = 0;
    _ = c_libs.ostree_repo_has_object(
        machine.data.repo,
        c_libs.OSTREE_OBJECT_TYPE_FILE,
        expected_c.ptr,
        &object_exists,
        null,
        null,
    );
    if (object_exists != 0) return FileFSMError.FileAlreadyExists;

    var written_file_checksum: ?[*]c_libs.guchar = null;
    if (c_libs.ostree_repo_write_content(machine.data.repo, expected_c.ptr, file_content_stream, file_content_length, &written_file_checksum, null, &gerror) == 0) {
        if (gerror) |err| c_libs.g_error_free(err);
        if (machine.exhausted()) return FileFSMError.RepoWriteFailed;
        machine.retries += 1;
        return stateWriteObject(machine);
    }
    if (written_file_checksum) |file_checksum| c_libs.g_free(@ptrCast(file_checksum));

    machine.resetRetries();
    return stateInsertMtree(machine);
}

fn stateInsertMtree(machine: *FileFSM) !void {
    try machine.enter(.insert_mtree);

    const checksum = machine.file_checksum orelse
        return FileFSMError.ChecksumFailed;

    insertIntoMtree(machine.data.mtree, machine.data.relative_path, checksum, machine.allocator) catch {
        if (machine.exhausted()) return FileFSMError.MtreeInsertFailed;
        machine.retries += 1;
        return stateInsertMtree(machine);
    };

    machine.resetRetries();
    return stateDone(machine);
}

fn stateDone(machine: *FileFSM) !void {
    try machine.enter(.done);
}

// ── Private helpers ───────────────────────────────────────────────────────────
fn insertIntoMtree(root: *c_libs.OstreeMutableTree, relative_path: []const u8, checksum: []const u8, allocator: std.mem.Allocator) !void {
    var gerror: ?*c_libs.GError = null;

    var file_path_components = std.ArrayList([]const u8).init(allocator);
    defer file_path_components.deinit();

    var file_path_components_iter = std.mem.splitScalar(u8, relative_path, '/');
    while (file_path_components_iter.next()) |file_path_part| {
        if (file_path_part.len > 0) try file_path_components.append(file_path_part);
    }
    if (file_path_components.items.len == 0) return FileFSMError.MtreeInsertFailed;

    const filename = file_path_components.items[file_path_components.items.len - 1];
    const dir_file_parts = file_path_components.items[0 .. file_path_components.items.len - 1];

    var current = root;
    for (dir_file_parts) |dir_name| {
        const dir_name_c = try allocator.dupeZ(u8, dir_name);
        defer allocator.free(dir_name_c);

        var sub_dir: ?*c_libs.OstreeMutableTree = null;
        if (c_libs.ostree_mutable_tree_ensure_dir(current, dir_name_c.ptr, &sub_dir, &gerror) == 0) {
            if (gerror) |err| c_libs.g_error_free(err);
            return FileFSMError.MtreeInsertFailed;
        }
        current = sub_dir.?;
    }

    const filename_c = try allocator.dupeZ(u8, filename);
    defer allocator.free(filename_c);

    const checksum_c = try allocator.dupeZ(u8, checksum);
    defer allocator.free(checksum_c);

    _ = c_libs.g_hash_table_insert(c_libs.ostree_mutable_tree_get_files(current), @ptrCast(c_libs.g_strdup(filename_c.ptr)), @ptrCast(c_libs.g_strdup(checksum_c.ptr)));
}
