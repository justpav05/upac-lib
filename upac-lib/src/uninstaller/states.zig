// ── Imports ─────────────────────────────────────────────────────────────────────
const std = @import("std");

const data = @import("upac-data");

const file = @import("upac-file");
const c_libs = file.c_libs;

const uninstaller_mod = @import("uninstaller.zig");
const UninstallerMachine = uninstaller_mod.UninstallerMachine;
const UninstallerError = uninstaller_mod.UninstallerError;

// ── States ─────────────────────────────────────────────────────────────────────
// The status of the path validation check
pub fn stateVerifying(machine: *UninstallerMachine) anyerror!void {
    try machine.enter(.verifying);

    std.fs.accessAbsolute(machine.data.repo_path, .{}) catch {
        stateFailed(machine);
        return UninstallerError.RepoPathNotFound;
    };

    machine.resetRetries();
    return stateOpenRepo(machine);
}

// The state of opening the repository and writing its data to the machine
fn stateOpenRepo(machine: *UninstallerMachine) anyerror!void {
    try machine.enter(.open_repo);

    const repo_path_c = std.fmt.allocPrintZ(machine.allocator, "{s}", .{machine.data.repo_path}) catch |err| {
        stateFailed(machine);
        return err;
    };
    defer machine.allocator.free(repo_path_c);

    var gerror: ?*c_libs.GError = null;

    const gfile = c_libs.g_file_new_for_path(repo_path_c.ptr);
    defer c_libs.g_object_unref(@ptrCast(gfile));

    const repo = c_libs.ostree_repo_new(gfile);

    if (c_libs.ostree_repo_open(repo, null, &gerror) == 0) {
        if (gerror) |err| c_libs.g_error_free(err);
        c_libs.g_object_unref(repo);
        if (machine.exhausted()) {
            stateFailed(machine);
            return UninstallerError.RepoOpenFailed;
        }
        machine.retries += 1;
        return stateOpenRepo(machine);
    }

    machine.repo = repo;

    const branch_c = std.fmt.allocPrintZ(machine.allocator, "{s}", .{machine.data.branch}) catch |err| {
        stateFailed(machine);
        return err;
    };
    defer machine.allocator.free(branch_c);

    var parent_checksum: ?[*:0]u8 = null;
    _ = c_libs.ostree_repo_resolve_rev(repo, branch_c.ptr, 1, &parent_checksum, null);

    const mtree = c_libs.ostree_mutable_tree_new();

    if (parent_checksum) |checksum| {
        defer c_libs.g_free(@ptrCast(checksum));

        var mtree_root: ?*c_libs.GFile = null;
        if (c_libs.ostree_repo_read_commit(repo, checksum, &mtree_root, null, null, &gerror) != 0) {
            defer if (mtree_root) |root| c_libs.g_object_unref(root);
            _ = c_libs.ostree_repo_write_directory_to_mtree(repo, mtree_root, mtree, null, null, &gerror);
            if (gerror) |err| c_libs.g_error_free(err);
        } else {
            if (gerror) |err| c_libs.g_error_free(err);
        }
    }

    machine.mtree = mtree;
    machine.resetRetries();
    return stateCheckInstalled(machine);
}

// Installation verification status, designed to prevent the removal of non-existent items
fn stateCheckInstalled(machine: *UninstallerMachine) anyerror!void {
    try machine.enter(.check_installed);

    const branch_c = try std.fmt.allocPrintZ(machine.allocator, "{s}", .{machine.data.branch});
    defer machine.allocator.free(branch_c);

    var last_checksum: ?[*:0]u8 = null;
    if (c_libs.ostree_repo_resolve_rev(machine.repo.?, branch_c.ptr, 1, &last_checksum, null) == 0 or last_checksum == null) {
        stateFailed(machine);
        return UninstallerError.PackageNotFound;
    }
    defer c_libs.g_free(@ptrCast(last_checksum));

    var gerror: ?*c_libs.GError = null;
    var commit_variant: ?*c_libs.GVariant = null;
    defer if (commit_variant) |variant| c_libs.g_variant_unref(variant);

    if (c_libs.ostree_repo_load_variant(machine.repo.?, c_libs.OSTREE_OBJECT_TYPE_COMMIT, last_checksum, &commit_variant, &gerror) == 0) {
        if (gerror) |err| c_libs.g_error_free(err);
        stateFailed(machine);
        return UninstallerError.PackageNotFound;
    }

    var body_variant: ?*c_libs.GVariant = null;
    defer if (body_variant) |variant| c_libs.g_variant_unref(variant);
    body_variant = c_libs.g_variant_get_child_value(commit_variant, 4);

    var body_len: usize = 0;
    const body_ptr = c_libs.g_variant_get_string(body_variant, &body_len);
    const body = body_ptr[0..body_len];

    var split_lines_iter = std.mem.splitScalar(u8, body, '\n');
    while (split_lines_iter.next()) |line| {
        const trimmed_line = std.mem.trim(u8, line, " \t\r");
        if (trimmed_line.len == 0) continue;

        const space_index = std.mem.indexOfScalar(u8, trimmed_line, ' ') orelse continue;
        const pkg_name = trimmed_line[0..space_index];
        const pkg_checksum = std.mem.trim(u8, trimmed_line[space_index + 1 ..], " \t");

        if (std.ascii.eqlIgnoreCase(pkg_name, machine.data.package_name)) {
            machine.package_checksum = try machine.allocator.dupe(u8, pkg_checksum);
            machine.resetRetries();
            return stateLoadFiles(machine);
        }
    }

    stateFailed(machine);
    return UninstallerError.PackageNotFound;
}

// State for loading the list of paths created during installation, in order to precisely identify which OSTree tree nodes need to be removed
fn stateLoadFiles(machine: *UninstallerMachine) anyerror!void {
    try machine.enter(.load_files);

    const pkg_checksum = machine.package_checksum orelse {
        stateFailed(machine);
        return UninstallerError.PackageNotFound;
    };

    const file_map = data.readFiles(machine.data.db_path, pkg_checksum, machine.allocator) catch |err| {
        if (machine.exhausted()) {
            stateFailed(machine);
            return err;
        }
        machine.retries += 1;
        return stateLoadFiles(machine);
    };

    machine.package_file_map = file_map;
    machine.resetRetries();
    return stateRemoveFiles(machine);
}

// State of file removal from mtree
fn stateRemoveFiles(machine: *UninstallerMachine) anyerror!void {
    try machine.enter(.remove_files);

    const file_map = machine.package_file_map orelse {
        stateFailed(machine);
        return UninstallerError.PackageNotFound;
    };

    var file_map_iter = file_map.iterator();
    while (file_map_iter.next()) |file_map_entry| {
        removeFromMtree(
            machine.mtree.?,
            file_map_entry.key_ptr.*,
            machine.allocator,
        ) catch |err| {
            stateFailed(machine);
            return err;
        };
    }

    machine.resetRetries();
    return stateRemoveDbFiles(machine);
}

// The state of removal from the global index, as well as of files belonging to the package in the database
fn stateRemoveDbFiles(machine: *UninstallerMachine) anyerror!void {
    try machine.enter(.remove_db_files);

    const pkg_checksum = machine.package_checksum orelse {
        stateFailed(machine);
        return UninstallerError.PackageNotFound;
    };

    const meta_filename = try std.fmt.allocPrint(
        machine.allocator,
        "{s}.meta",
        .{pkg_checksum},
    );
    defer machine.allocator.free(meta_filename);

    const files_filename = try std.fmt.allocPrint(
        machine.allocator,
        "{s}.files",
        .{pkg_checksum},
    );
    defer machine.allocator.free(files_filename);

    removeFromMtree(machine.mtree.?, meta_filename, machine.allocator) catch |err| {
        stateFailed(machine);
        return err;
    };

    removeFromMtree(machine.mtree.?, files_filename, machine.allocator) catch |err| {
        stateFailed(machine);
        return err;
    };

    machine.resetRetries();
    return stateCommit(machine);
}

// Creates a new commit in OSTree representing the system state without the files of this package
fn stateCommit(machine: *UninstallerMachine) anyerror!void {
    try machine.enter(.commit);

    const repo = machine.repo.?;
    const mtree = machine.mtree.?;

    var gerror: ?*c_libs.GError = null;

    const branch_c = try std.fmt.allocPrintZ(
        machine.allocator,
        "{s}",
        .{machine.data.branch},
    );
    defer machine.allocator.free(branch_c);

    const root_path_c = try std.fmt.allocPrintZ(machine.allocator, "{s}", .{machine.data.root_path});
    defer machine.allocator.free(root_path_c);

    var parent_checksum: ?[*:0]u8 = null;
    defer if (parent_checksum) |checksum| c_libs.g_free(@ptrCast(checksum));
    _ = c_libs.ostree_repo_resolve_rev(repo, branch_c.ptr, 1, &parent_checksum, null);

    var body_buf = std.ArrayList(u8).init(machine.allocator);
    defer body_buf.deinit();
    const body_writer = body_buf.writer();

    if (parent_checksum) |prev_checksum| {
        var prev_commit_variant: ?*c_libs.GVariant = null;
        defer if (prev_commit_variant) |variant| c_libs.g_variant_unref(variant);

        if (c_libs.ostree_repo_load_variant(repo, c_libs.OSTREE_OBJECT_TYPE_COMMIT, prev_checksum, &prev_commit_variant, &gerror) != 0) {
            var prev_body_variant: ?*c_libs.GVariant = null;
            defer if (prev_body_variant) |variant| c_libs.g_variant_unref(variant);
            prev_body_variant = c_libs.g_variant_get_child_value(prev_commit_variant, 4);

            var prev_body_len: usize = 0;
            const prev_body_ptr = c_libs.g_variant_get_string(prev_body_variant, &prev_body_len);
            const prev_body = prev_body_ptr[0..prev_body_len];

            var split_lines_iter = std.mem.splitScalar(u8, prev_body, '\n');
            while (split_lines_iter.next()) |line| {
                const trimmed_line = std.mem.trim(u8, line, " \t\r");
                if (trimmed_line.len == 0) continue;

                const space_index = std.mem.indexOfScalar(u8, trimmed_line, ' ') orelse continue;
                const pkg_name = trimmed_line[0..space_index];

                if (!std.ascii.eqlIgnoreCase(pkg_name, machine.data.package_name)) {
                    try body_writer.print("{s}\n", .{trimmed_line});
                }
            }
        } else {
            if (gerror) |err| c_libs.g_error_free(err);
        }
    }

    const body_c = try machine.allocator.dupeZ(u8, body_buf.items);
    defer machine.allocator.free(body_c);

    if (c_libs.ostree_repo_prepare_transaction(repo, null, null, &gerror) == 0) {
        if (gerror) |err| c_libs.g_error_free(err);
        if (machine.exhausted()) {
            stateFailed(machine);
            return UninstallerError.MaxRetriesExceeded;
        }
        machine.retries += 1;
        return stateCommit(machine);
    }

    var mtree_root: ?*c_libs.GFile = null;
    defer if (mtree_root) |root| c_libs.g_object_unref(root);

    if (c_libs.ostree_repo_write_mtree(repo, mtree, &mtree_root, null, &gerror) == 0) {
        if (gerror) |err| c_libs.g_error_free(err);
        _ = c_libs.ostree_repo_abort_transaction(repo, null, null);
        if (machine.exhausted()) {
            stateFailed(machine);
            return UninstallerError.MaxRetriesExceeded;
        }
        machine.retries += 1;
        return stateCommit(machine);
    }

    const subject_c = try std.fmt.allocPrintZ(machine.allocator, "remove: {s}", .{machine.data.package_name});
    defer machine.allocator.free(subject_c);

    var commit_checksum: ?[*:0]u8 = null;
    defer if (commit_checksum) |checksum| c_libs.g_free(@ptrCast(checksum));

    if (c_libs.ostree_repo_write_commit(repo, if (parent_checksum) |checksum| checksum else null, subject_c.ptr, body_c.ptr, null, @ptrCast(mtree_root), &commit_checksum, null, &gerror) == 0) {
        if (gerror) |err| c_libs.g_error_free(err);
        _ = c_libs.ostree_repo_abort_transaction(repo, null, null);
        if (machine.exhausted()) {
            stateFailed(machine);
            return UninstallerError.MaxRetriesExceeded;
        }
        machine.retries += 1;
        return stateCommit(machine);
    }

    c_libs.ostree_repo_transaction_set_ref(repo, null, branch_c.ptr, commit_checksum);

    if (c_libs.ostree_repo_commit_transaction(repo, null, null, &gerror) == 0) {
        if (gerror) |err| c_libs.g_error_free(err);
        if (machine.exhausted()) {
            stateFailed(machine);
            return UninstallerError.MaxRetriesExceeded;
        }
        machine.retries += 1;
        return stateCommit(machine);
    }

    var checkout_options = std.mem.zeroes(c_libs.OstreeRepoCheckoutAtOptions);
    checkout_options.mode = c_libs.OSTREE_REPO_CHECKOUT_MODE_NONE;
    checkout_options.overwrite_mode = c_libs.OSTREE_REPO_CHECKOUT_OVERWRITE_UNION_FILES;

    if (c_libs.ostree_repo_checkout_at(repo, &checkout_options, std.c.AT.FDCWD, root_path_c.ptr, commit_checksum, null, &gerror) == 0) {
        if (gerror) |err| c_libs.g_error_free(err);
        if (machine.exhausted()) {
            stateFailed(machine);
            return UninstallerError.MaxRetriesExceeded;
        }
        machine.retries += 1;
        return stateCommit(machine);
    }

    machine.resetRetries();
    return stateDone(machine);
}

// State of successful completion of the package removal process and deployment of the new commit
fn stateDone(machine: *UninstallerMachine) anyerror!void {
    try machine.enter(.done);
}

// A state of unsuccessful package removal, signaling the system that a rollback is required to revert the changes
fn stateFailed(machine: *UninstallerMachine) void {
    _ = machine.enter(.failed) catch {};
    // std.debug.print("uninstall failed '{s}', states: ", .{machine.data.package_name});
    // for (machine.stack.items) |state| {
    //     std.debug.print("{s} ", .{@tagName(state)});
    // }
    // std.debug.print("\n", .{}); -- Debug information
}

// ── Helpers functions ─────────────────────────────────────────────────────────────────────
// Removes the file entry from the file table of the corresponding directory
fn removeFromMtree(root: *c_libs.OstreeMutableTree, relative_path: []const u8, allocator: std.mem.Allocator) !void {
    var gerror: ?*c_libs.GError = null;

    var path_components = std.ArrayList([]const u8).init(allocator);
    defer path_components.deinit();

    var path_components_iter = std.mem.splitScalar(u8, relative_path, '/');
    while (path_components_iter.next()) |path_part| {
        if (path_part.len > 0) try path_components.append(path_part);
    }
    if (path_components.items.len == 0) return;

    const filename = path_components.items[path_components.items.len - 1];
    const dir_parts = path_components.items[0 .. path_components.items.len - 1];

    var current_mtree = root;
    for (dir_parts) |dir_name| {
        const dir_name_c = try allocator.dupeZ(u8, dir_name);
        defer allocator.free(dir_name_c);

        var sub_dir: ?*c_libs.OstreeMutableTree = null;
        if (c_libs.ostree_mutable_tree_ensure_dir(current_mtree, dir_name_c.ptr, &sub_dir, &gerror) == 0) {
            if (gerror) |err| c_libs.g_error_free(err);
            return;
        }
        current_mtree = sub_dir.?;
    }

    const filename_c = try allocator.dupeZ(u8, filename);
    defer allocator.free(filename_c);

    _ = c_libs.ostree_mutable_tree_remove(current_mtree, filename_c.ptr, 0, &gerror);
    if (gerror) |err| c_libs.g_error_free(err);
}
