// ── Imports ─────────────────────────────────────────────────────────────────────
const installer = @import("installer.zig");
const std = installer.std;
const c_libs = installer.c_libs;

const data = installer.data;

const InstallerMachine = installer.InstallerMachine;
const InstallerError = installer.InstallerError;

// ── Helpers functions ───────────────────────────────────────────────────
// A recursive assistant. It traverses the directory structure, calculates checksums for all files, and populates the FileMap. It is precisely this data that is subsequently written to the `.files` file within the database
pub fn collectFileChecksums(machine: *InstallerMachine, root_path: []const u8, prefix: []const u8, file_map: *data.FileMap) !void {
    var gerror: ?*c_libs.GError = null;
    defer if (gerror) |err| c_libs.g_error_free(err);

    var dir_stack = std.ArrayList([]const u8).empty;
    defer {
        for (dir_stack.items) |path| machine.allocator.free(path);
        dir_stack.deinit(machine.allocator);
    }

    try dir_stack.append(machine.allocator, try machine.allocator.dupe(u8, root_path));

    while (dir_stack.items.len > 0) {
        if (machine.cancellable) |cancellable| if (c_libs.g_cancellable_is_cancelled(cancellable) != 0) return InstallerError.Cancelled;

        const current_path = try machine.unwrap(dir_stack.pop(), InstallerError.AllocZFailed);
        defer machine.allocator.free(current_path);

        var dir = std.fs.openDirAbsolute(current_path, .{ .iterate = true }) catch continue;
        defer dir.close();

        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            const entry_path = try std.fs.path.join(machine.allocator, &.{ current_path, entry.name });

            switch (entry.kind) {
                .directory => try dir_stack.append(machine.allocator, entry_path),
                .file, .sym_link => {
                    defer machine.allocator.free(entry_path);

                    const entry_path_c = try machine.allocator.dupeZ(u8, entry_path);
                    defer machine.allocator.free(entry_path_c);

                    const gfile = c_libs.g_file_new_for_path(entry_path_c.ptr);
                    defer c_libs.g_object_unref(@ptrCast(gfile));

                    var raw_checksum_bin: [*c]u8 = null;
                    if (c_libs.ostree_checksum_file(gfile, c_libs.OSTREE_OBJECT_TYPE_FILE, &raw_checksum_bin, machine.cancellable, &gerror) == 0)
                        return InstallerError.CollectFileChecksumsFailed;
                    defer c_libs.g_free(@ptrCast(raw_checksum_bin));

                    var hex_buf: [65]u8 = undefined;
                    c_libs.ostree_checksum_inplace_from_bytes(raw_checksum_bin.?, &hex_buf);

                    const relative = entry_path[prefix.len..];
                    try file_map.put(
                        try machine.allocator.dupe(u8, relative),
                        try machine.allocator.dupe(u8, hex_buf[0..64]),
                    );
                },
                else => machine.allocator.free(entry_path),
            }
        }
    }
}

pub fn dirSize(allocator: std.mem.Allocator, root_path: []const u8) !u64 {
    var total_size: u64 = 0;

    var dir_stack = std.ArrayList([]const u8).empty;
    defer {
        for (dir_stack.items) |p| allocator.free(p);
        dir_stack.deinit(allocator);
    }
    try dir_stack.append(allocator, try allocator.dupe(u8, root_path));

    while (dir_stack.items.len > 0) {
        const current = dir_stack.pop() orelse return InstallerError.AllocZFailed;
        defer allocator.free(current);

        var dir = std.fs.openDirAbsolute(current, .{ .iterate = true }) catch continue;
        defer dir.close();

        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            const entry_path = try std.fs.path.join(allocator, &.{ current, entry.name });
            switch (entry.kind) {
                .file => {
                    defer allocator.free(entry_path);
                    const s = std.fs.cwd().statFile(entry_path) catch continue;
                    total_size += s.size;
                },
                .directory => try dir_stack.append(allocator, entry_path),
                else => allocator.free(entry_path),
            }
        }
    }
    return total_size;
}

pub fn estimateCheckoutSize(machine: *InstallerMachine, repo: *c_libs.OstreeRepo, commit_checksum: [*:0]const u8, cancellable: ?*c_libs.GCancellable) !u64 {
    var gerror: ?*c_libs.GError = null;
    defer if (gerror) |err| c_libs.g_error_free(err);

    var root_file: ?*anyopaque = null;
    var root_info: ?*anyopaque = null;
    defer if (root_file) |file| c_libs.g_object_unref(file);
    defer if (root_info) |info| c_libs.g_object_unref(info);

    if (c_libs.ostree_repo_read_commit(repo, commit_checksum, @ptrCast(&root_file), @ptrCast(&root_info), cancellable, &gerror) == 0) return error.RepoOpenFailed;

    const root_file_unwraped = try machine.unwrap(root_file, InstallerError.CheckSpaceFailed);

    return walkTree(repo, @ptrCast(root_file_unwraped), cancellable);
}

fn walkTree(repo: *c_libs.OstreeRepo, dir: *anyopaque, cancellable: ?*c_libs.GCancellable) !u64 {
    var gerror: ?*c_libs.GError = null;
    defer if (gerror) |err| c_libs.g_error_free(err);

    var total: u64 = 0;

    const enumerator = c_libs.g_file_enumerate_children(@ptrCast(dir), "standard::name,standard::type,standard::size", c_libs.G_FILE_QUERY_INFO_NOFOLLOW_SYMLINKS, cancellable, &gerror) orelse return error.DiffFailed;
    defer c_libs.g_object_unref(enumerator);

    while (true) {
        const info: ?*anyopaque = c_libs.g_file_enumerator_next_file(enumerator, cancellable, &gerror);
        if (info == null) break;
        defer c_libs.g_object_unref(info);

        const file_type = c_libs.g_file_info_get_file_type(@ptrCast(info));
        const child_name = c_libs.g_file_info_get_name(@ptrCast(info));

        const child: ?*anyopaque = c_libs.g_file_get_child(@ptrCast(dir), child_name);
        defer if (child) |c| c_libs.g_object_unref(c);

        if (file_type == c_libs.G_FILE_TYPE_DIRECTORY) {
            total += try walkTree(repo, child orelse continue, cancellable);
        } else {
            total += @intCast(c_libs.g_file_info_get_size(@ptrCast(info)));
        }
    }

    return total;
}

pub fn onCancelSignal(user_data: c_libs.gpointer) callconv(.c) c_libs.gboolean {
    const cancellable = @as(*c_libs.GCancellable, @ptrCast(@alignCast(user_data)));
    c_libs.g_cancellable_cancel(cancellable);
    return c_libs.G_SOURCE_REMOVE;
}

pub fn signalLoopThread(loop: *c_libs.GMainLoop) void {
    c_libs.g_main_loop_run(loop);
}
