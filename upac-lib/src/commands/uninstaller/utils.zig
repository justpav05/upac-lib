// ── Imports ─────────────────────────────────────────────────────────────────────
const uninstaller = @import("uninstaller.zig");

const std = uninstaller.std;
const c_libs = uninstaller.c_libs;

const UninstallerMachine = uninstaller.UninstallerMachine;
const UninstallerError = uninstaller.UninstallerError;

const stateFailed = uninstaller.stateFailed;

// ── Helpers functions ─────────────────────────────────────────────────────────────────────
// Removes the file entry from the file table of the corresponding directory
pub fn removeFromMtree(repo: *c_libs.OstreeRepo, root_mtree: *c_libs.OstreeMutableTree, relative_path: []const u8, allocator: std.mem.Allocator) UninstallerError!void {
    var gerror: ?*c_libs.GError = null;
    defer if (gerror) |err| c_libs.g_error_free(@ptrCast(err));

    var path_components = std.ArrayList([]const u8).init(allocator);
    defer path_components.deinit();

    var path_components_iter = std.mem.splitScalar(u8, relative_path, '/');
    while (path_components_iter.next()) |path_part| {
        if (path_part.len > 0) path_components.append(path_part) catch return error.AllocZFailed;
    }
    if (path_components.items.len == 0) return;

    var current_subtree = root_mtree;
    for (path_components.items[0 .. path_components.items.len - 1]) |directory_component| {
        const contents_checksum = c_libs.ostree_mutable_tree_get_contents_checksum(current_subtree);
        const metadata_checksum = c_libs.ostree_mutable_tree_get_metadata_checksum(current_subtree);
        if (contents_checksum != null and metadata_checksum != null) {
            _ = c_libs.ostree_mutable_tree_fill_empty_from_dirtree(current_subtree, repo, contents_checksum, metadata_checksum);
        }

        const directory_component_c = allocator.dupeZ(u8, directory_component) catch return error.AllocZFailed;
        defer allocator.free(directory_component_c);

        var out_file_checksum: [*c]u8 = null;
        var out_subdir: ?*c_libs.OstreeMutableTree = null;

        if (c_libs.ostree_mutable_tree_lookup(current_subtree, directory_component_c.ptr, &out_file_checksum, &out_subdir, &gerror) == 0) return error.FileNotFound;

        if (out_subdir == null) return;
        current_subtree = out_subdir.?;
    }

    const contents_checksum = c_libs.ostree_mutable_tree_get_contents_checksum(current_subtree);
    const metadata_checksum = c_libs.ostree_mutable_tree_get_metadata_checksum(current_subtree);
    if (contents_checksum != null and metadata_checksum != null) {
        _ = c_libs.ostree_mutable_tree_fill_empty_from_dirtree(current_subtree, repo, contents_checksum, metadata_checksum);
    }

    const file_name_c = allocator.dupeZ(u8, path_components.items[path_components.items.len - 1]) catch return error.AllocZFailed;
    defer allocator.free(file_name_c);

    if (c_libs.ostree_mutable_tree_remove(current_subtree, file_name_c.ptr, 0, &gerror) == 0) return error.FileNotFound;
}

pub fn resolveMtree(machine: *UninstallerMachine, repo: *c_libs.OstreeRepo) ?*c_libs.OstreeMutableTree {
    if (c_libs.ostree_repo_resolve_rev(repo, machine.data.branch, 0, &machine.previous_commit_checksum, null) != 0) {
        if (c_libs.ostree_mutable_tree_new_from_commit(repo, machine.previous_commit_checksum, &machine.gerror)) |mtree| {
            return mtree;
        }
    }
    return c_libs.ostree_mutable_tree_new();
}

pub fn removeDbFile(machine: *UninstallerMachine, repo: *c_libs.OstreeRepo, mtree: *c_libs.OstreeMutableTree, pkg_checksum: []const u8, relative_db_path: []const u8, comptime ext: []const u8) UninstallerError!void {
    var buf: [256]u8 = undefined;

    const filename = std.fmt.bufPrint(&buf, "{s}" ++ ext, .{pkg_checksum}) catch return error.AllocZFailed;
    const path = std.fs.path.join(machine.allocator, &.{ relative_db_path, filename }) catch return error.AllocZFailed;
    defer machine.allocator.free(path);

    removeFromMtree(repo, mtree, path, machine.allocator) catch {
        stateFailed(machine);
        return error.FileNotFound;
    };
}

pub fn buildCommitBody(machine: *UninstallerMachine, repo: *c_libs.OstreeRepo, prev_checksum: [*:0]u8, writer: anytype) UninstallerError!void {
    var prev_commit_variant: ?*c_libs.GVariant = null;
    defer if (prev_commit_variant) |v| c_libs.g_variant_unref(v);

    if (c_libs.ostree_repo_load_variant(repo, c_libs.OSTREE_OBJECT_TYPE_COMMIT, prev_checksum, &prev_commit_variant, &machine.gerror) == 0) return;

    var prev_body_variant: ?*c_libs.GVariant = null;
    defer if (prev_body_variant) |variant| c_libs.g_variant_unref(variant);

    prev_body_variant = c_libs.g_variant_get_child_value(prev_commit_variant, 4);

    var len: usize = 0;
    const body = c_libs.g_variant_get_string(prev_body_variant, &len)[0..len];

    var body_iter = std.mem.splitScalar(u8, body, '\n');
    while (body_iter.next()) |line| {
        const trimmed_line = std.mem.trim(u8, line, " \t\r");
        if (trimmed_line.len == 0) continue;

        const separator_index = std.mem.indexOfScalar(u8, trimmed_line, ' ') orelse continue;
        const package_name = trimmed_line[0..separator_index];

        const should_remove = for (machine.data.package_names) |name| {
            if (std.ascii.eqlIgnoreCase(package_name, name)) break true;
        } else false;

        if (!should_remove) try writer.print("{s}\n", .{trimmed_line});
    }
}

pub fn buildCommitSubject(machine: *UninstallerMachine) UninstallerError![:0]u8 {
    var buf = std.ArrayList(u8).init(machine.allocator);
    defer buf.deinit();

    try buf.appendSlice("remove:");
    for (machine.data.package_names, 0..) |name, index| {
        try buf.writer().print("{s}{s}", .{ if (index == 0) " " else ", ", name });
    }

    return machine.allocator.dupeZ(u8, buf.items) catch error.AllocZFailed;
}

pub fn onCancelSignal(user_data: c_libs.gpointer) callconv(.C) c_libs.gboolean {
    const cancellable = @as(*c_libs.GCancellable, @ptrCast(@alignCast(user_data)));
    c_libs.g_cancellable_cancel(cancellable);
    return c_libs.G_SOURCE_REMOVE;
}

pub fn signalLoopThread(loop: *c_libs.GMainLoop) void {
    c_libs.g_main_loop_run(loop);
}
