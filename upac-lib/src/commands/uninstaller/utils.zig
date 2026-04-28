// ── Imports ─────────────────────────────────────────────────────────────────────
const uninstaller = @import("uninstaller.zig");

const std = uninstaller.std;
const c_libs = uninstaller.c_libs;

const UninstallerMachine = uninstaller.UninstallerMachine;
const UninstallerError = uninstaller.UninstallerError;

const stateFailed = uninstaller.stateFailed;

// ── Helpers functions ─────────────────────────────────────────────────────────────────────
pub fn removeFromMtree(repo: *c_libs.OstreeRepo, root_mtree: *c_libs.OstreeMutableTree, relative_path: []const u8, allocator: std.mem.Allocator) UninstallerError!void {
    _ = repo;

    var gerror: ?*c_libs.GError = null;
    defer if (gerror) |err| c_libs.g_error_free(@ptrCast(err));

    var path_components = std.ArrayList([]const u8).empty;
    defer path_components.deinit(allocator);

    var path_components_iter = std.mem.splitScalar(u8, relative_path, '/');
    while (path_components_iter.next()) |path_part| {
        if (path_part.len > 0) path_components.append(allocator, path_part) catch return error.AllocZFailed;
    }
    if (path_components.items.len == 0) return;

    var current_subtree: *c_libs.OstreeMutableTree = @ptrCast(@alignCast(c_libs.g_object_ref(root_mtree)));
    defer c_libs.g_object_unref(current_subtree);

    for (path_components.items[0 .. path_components.items.len - 1]) |directory_component| {
        const directory_component_c = allocator.dupeZ(u8, directory_component) catch return error.AllocZFailed;
        defer allocator.free(directory_component_c);

        var out_file_checksum: [*c]u8 = null;
        var out_subdir: ?*c_libs.OstreeMutableTree = null;

        // `ostree_mutable_tree_lookup` lazily materialises the subtree from the
        // underlying commit, so it is the right primitive to use here.
        if (c_libs.ostree_mutable_tree_lookup(current_subtree, directory_component_c.ptr, &out_file_checksum, &out_subdir, &gerror) == 0) {
            if (out_file_checksum != null) c_libs.g_free(out_file_checksum);
            return error.FileNotFound;
        }

        if (out_file_checksum != null) c_libs.g_free(out_file_checksum);

        const next = out_subdir orelse return error.FileNotFound;
        c_libs.g_object_unref(current_subtree);
        current_subtree = next;
    }

    const file_name_c = allocator.dupeZ(u8, path_components.items[path_components.items.len - 1]) catch return error.AllocZFailed;
    defer allocator.free(file_name_c);

    if (c_libs.ostree_mutable_tree_remove(current_subtree, file_name_c.ptr, 1, &gerror) == 0) return error.FileNotFound;
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

    try machine.check(removeFromMtree(repo, mtree, path, machine.allocator), UninstallerError.FileNotFound);
}

pub fn buildCommitBody(machine: *UninstallerMachine, repo: *c_libs.OstreeRepo, prev_checksum: [*:0]u8, writer: *std.Io.Writer) UninstallerError!void {
    var prev_commit_variant: ?*c_libs.GVariant = null;
    defer if (prev_commit_variant) |variant| c_libs.g_variant_unref(variant);

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

        if (!should_remove) try machine.check(writer.print("{s}\n", .{trimmed_line}), UninstallerError.AllocZFailed);
    }
}

pub fn buildCommitSubject(machine: *UninstallerMachine) UninstallerError![:0]u8 {
    var buf = std.Io.Writer.Allocating.init(machine.allocator);
    defer buf.deinit();
    const writer = &buf.writer;

    try machine.check(writer.writeAll("remove:"), UninstallerError.AllocZFailed);
    for (machine.data.package_names, 0..) |name, index| try machine.check(writer.print("{s}{s}", .{ if (index == 0) " " else ", ", name }), UninstallerError.AllocZFailed);

    return machine.check(machine.allocator.dupeZ(u8, buf.written()), UninstallerError.AllocZFailed);
}
