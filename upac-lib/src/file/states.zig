// ── Imports ─────────────────────────────────────────────────────────────────────
const std = @import("std");

const file = @import("file.zig");
const c_libs = file.c_libs;

const FileFSM = file.FileFSM;
const FileError = file.FileError;

// ── States ────────────────────────────────────────────────────────────────────
// Uses the ostree library to compute a file's hash based on its temporary path. On success, it saves the hash to the machine; on failure, it initiates a retry or terminates with an error
fn stateChecksum(machine: *FileFSM) FileError!void {
    try machine.enter(.checksum);

    const gfile = c_libs.g_file_new_for_path(machine.data.temp_path.ptr);
    defer c_libs.g_object_unref(@ptrCast(gfile));

    var raw_checksum: ?[*:0]u8 = null;
    defer c_libs.g_free(@ptrCast(raw_checksum));

    if (c_libs.ostree_checksum_file(gfile, c_libs.OSTREE_OBJECT_TYPE_FILE, &raw_checksum, machine.cancellable, &machine.gerror) == 0) return machine.retry(stateChecksum, FileError.ChecksumFailed);

    machine.file_checksum = try machine.allocator.dupe(u8, std.mem.span(raw_checksum.?));
    machine.resetRetries();
    return stateWriteObject(machine);
}
// Responsible for physically writing a file to the OSTree repository as a "loose object." If the write operation fails, it increments the attempt counter and retries
fn stateWriteObject(machine: *FileFSM) !void {
    try machine.enter(.write_object);

    const gfile = c_libs.g_file_new_for_path(machine.data.temp_path.ptr);
    defer c_libs.g_object_unref(@ptrCast(gfile));

    const file_info = try machine.unwrap(c_libs.g_file_query_info(gfile, "standard::*,unix::*", c_libs.G_FILE_QUERY_INFO_NOFOLLOW_SYMLINKS, null, &machine.gerror), FileError.FileNotFound);
    defer c_libs.g_object_unref(@ptrCast(file_info));

    const raw_file_stream = c_libs.g_file_read(gfile, null, &machine.gerror) orelse return machine.retry(stateWriteObject, FileError.RepoWriteFailed);
    defer c_libs.g_object_unref(@ptrCast(raw_file_stream));

    var file_content_stream: ?*c_libs.GInputStream = null;
    defer c_libs.g_object_unref(@ptrCast(file_content_stream));

    var file_content_length: c_libs.guint64 = 0;

    if (c_libs.ostree_raw_file_to_content_stream(@ptrCast(raw_file_stream), file_info, null, &file_content_stream, &file_content_length, machine.cancellable, &machine.gerror) == 0) return machine.retry(stateWriteObject, FileError.RepoWriteFailed);

    const expected_checksum = try machine.unwrap(machine.file_checksum, FileError.ChecksumFailed);
    const expected_checksum_c = try machine.allocator.dupeZ(u8, expected_checksum);
    defer machine.allocator.free(expected_checksum_c);

    var object_exists: c_libs.gboolean = 0;
    _ = c_libs.ostree_repo_has_object(machine.data.repo, c_libs.OSTREE_OBJECT_TYPE_FILE, expected_checksum_c.ptr, &object_exists, machine.cancellable, null);

    if (object_exists != 0) {
        machine.resetRetries();
        return stateInsertMtree(machine);
    }

    var written_checksum_bin: ?[*]c_libs.guchar = null;
    if (c_libs.ostree_repo_write_content(machine.data.repo, null, file_content_stream, file_content_length, &written_checksum_bin, machine.cancellable, &machine.gerror) == 0) return machine.retry(stateWriteObject, FileError.RepoWriteFailed);
    defer if (written_checksum_bin) |checksum_bin| c_libs.g_free(@ptrCast(checksum_bin));

    if (machine.file_checksum) |checksum| machine.allocator.free(checksum);

    var hex_buf: [65]u8 = undefined;
    c_libs.ostree_checksum_inplace_from_bytes(written_checksum_bin.?, &hex_buf);
    machine.file_checksum = try machine.allocator.dupe(u8, hex_buf[0..64]);

    machine.resetRetries();
    return stateInsertMtree(machine);
}

// The most complex part is inserting an object into a mutable tree (OstreeMutableTree). It splits the path into components, ensures the existence of all parent directories, and binds the file to the tree
fn stateInsertMtree(machine: *FileFSM) !void {
    try machine.enter(.insert_mtree);

    const checksum = try machine.unwrap(machine.file_checksum, FileError.ChecksumFailed);

    insertIntoMtree(machine.data.mtree, machine.data.relative_path, checksum, machine.allocator) catch return machine.retry(stateInsertMtree, FileError.MtreeInsertFailed);

    machine.resetRetries();
    return stateDone(machine);
}

// The final state of the FileFSM automaton. It signals the successful completion of all file processing stages (hashing, object writing, and tree insertion) and terminates the state machine's operational cycle
fn stateDone(machine: *FileFSM) !void {
    try machine.enter(.done);
}

// ── Private helpers ───────────────────────────────────────────────────────────
// The "path builder" within OSTree is responsible for ensuring that a file ends up exactly where it belongs in the installed system
fn insertIntoMtree(machine: FileFSM, root: *c_libs.OstreeMutableTree, relative_path: []const u8, checksum: []const u8, allocator: std.mem.Allocator) FileError!void {
    const last_slash = try machine.unwrap(std.mem.lastIndexOfScalar(u8, relative_path, '/'), FileError.MtreeInsertFailed);

    const dir_part = relative_path[0..last_slash];
    const filename = relative_path[last_slash + 1 ..];
    if (filename.len == 0) return FileError.MtreeInsertFailed;

    var current = root;
    var dir_iter = std.mem.tokenizeScalar(u8, dir_part, '/');
    while (dir_iter.next()) |dir_name| {
        const dir_name_c = try allocator.dupeZ(u8, dir_name);
        defer allocator.free(dir_name_c);

        var sub_dir: ?*c_libs.OstreeMutableTree = null;
        if (c_libs.ostree_mutable_tree_ensure_dir(current, dir_name_c.ptr, &sub_dir, &machine.gerror) == 0) return FileError.MtreeInsertFailed;

        current = sub_dir.?;
    }

    const filename_c = try allocator.dupeZ(u8, filename);
    defer allocator.free(filename_c);

    const checksum_c = try allocator.dupeZ(u8, checksum);
    defer allocator.free(checksum_c);

    if (c_libs.ostree_mutable_tree_replace_file(current, filename_c.ptr, checksum_c.ptr, &machine.gerror) == 0) return FileError.MtreeInsertFailed;

    var lookup_checksum: ?[*:0]u8 = null;
    defer if (lookup_checksum) |checksm| c_libs.g_free(@ptrCast(checksm));
    var lookup_subdir: ?*c_libs.OstreeMutableTree = null;
    if (c_libs.ostree_mutable_tree_lookup(current, filename_c.ptr, &lookup_checksum, &lookup_subdir, &machine.gerror) == 0) return FileError.MtreeInsertFailed;

    if (lookup_checksum == null) return FileError.MtreeInsertFailed;
}
