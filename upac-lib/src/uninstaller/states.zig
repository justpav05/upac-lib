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
fn stateOpenRepo(machine: *UninstallerMachine) !void {
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

    if (c_libs.ostree_repo_prepare_transaction(repo, null, null, &gerror) == 0) {
        if (gerror) |err| c_libs.g_error_free(err);
        if (machine.exhausted()) {
            stateFailed(machine);
            return UninstallerError.MaxRetriesExceeded;
        }
        machine.retries += 1;
        return stateCheckInstalled(machine);
    }

    const branch_c = std.fmt.allocPrintZ(machine.allocator, "{s}", .{machine.data.branch}) catch |err| {
        stateFailed(machine);
        return err;
    };
    defer machine.allocator.free(branch_c);

    var parent_checksum: ?[*:0]u8 = null;
    _ = c_libs.ostree_repo_resolve_rev(repo, branch_c.ptr, 1, &parent_checksum, null);

    var uninstaller_mtree: ?*c_libs.OstreeMutableTree = null;

    if (parent_checksum) |checksum| {
        const existing_mtree = c_libs.ostree_mutable_tree_new_from_commit(repo, checksum, &gerror);
        if (existing_mtree) |mtree| {
            uninstaller_mtree = mtree;
        }
        c_libs.g_free(@ptrCast(checksum));
    } else {
        uninstaller_mtree = c_libs.ostree_mutable_tree_new();
    }

    machine.mtree = uninstaller_mtree.?;
    machine.resetRetries();
    return stateCheckInstalled(machine);
}

// Installation verification status, designed to prevent the removal of non-existent items
fn stateCheckInstalled(machine: *UninstallerMachine) !void {
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

        if (std.ascii.eqlIgnoreCase(pkg_name, machine.data.package_names[machine.current_package_index])) {
            machine.package_checksum = try machine.allocator.dupe(u8, pkg_checksum);
            machine.resetRetries();
            return stateLoadFiles(machine);
        }
    }

    stateFailed(machine);
    return UninstallerError.PackageNotFound;
}

// State for loading the list of paths created during installation, in order to precisely identify which OSTree tree nodes need to be removed
fn stateLoadFiles(machine: *UninstallerMachine) !void {
    try machine.enter(.load_files);

    const pkg_checksum = machine.package_checksum orelse {
        stateFailed(machine);
        return UninstallerError.PackageNotFound;
    };

    const file_map = data.readFiles(machine.data.db_path, pkg_checksum, machine.allocator) catch {
        stateFailed(machine);
        return UninstallerError.FileMapCorrupted;
    };

    machine.package_file_map = file_map;
    machine.resetRetries();
    return stateRemoveFiles(machine);
}

// State of file removal from mtree
fn stateRemoveFiles(machine: *UninstallerMachine) !void {
    try machine.enter(.remove_files);

    const repo = machine.repo orelse {
        stateFailed(machine);
        return UninstallerError.RepoOpenFailed;
    };

    const file_map = machine.package_file_map orelse {
        stateFailed(machine);
        return UninstallerError.PackageNotFound;
    };
    const mtree = machine.mtree orelse {
        stateFailed(machine);
        return UninstallerError.PackageNotFound;
    };

    var iter = file_map.iterator();
    while (iter.next()) |entry| {
        removeFromMtree(repo, mtree, entry.key_ptr.*, machine.allocator) catch {
            if (machine.exhausted()) {
                stateFailed(machine);
                return UninstallerError.FileNotFound;
            }
            machine.retries += 1;
            return stateRemoveFiles(machine);
        };
    }

    machine.resetRetries();
    return stateRemoveDbFiles(machine);
}

// The state of removal from the global index, as well as of files belonging to the package in the database
fn stateRemoveDbFiles(machine: *UninstallerMachine) !void {
    try machine.enter(.remove_db_files);

    const repo = machine.repo orelse {
        stateFailed(machine);
        return UninstallerError.RepoOpenFailed;
    };

    const pkg_checksum = machine.package_checksum orelse {
        stateFailed(machine);
        return UninstallerError.PackageNotFound;
    };
    const mtree = machine.mtree orelse {
        stateFailed(machine);
        return UninstallerError.RepoOpenFailed;
    };

    const relative_database_path = if (std.mem.startsWith(u8, machine.data.db_path, machine.data.root_path))
        machine.data.db_path[machine.data.root_path.len..]
    else
        machine.data.db_path;

    const meta_relative_path = try std.fmt.allocPrint(machine.allocator, "{s}/{s}.meta", .{ relative_database_path, pkg_checksum });
    defer machine.allocator.free(meta_relative_path);

    removeFromMtree(repo, mtree, meta_relative_path, machine.allocator) catch {
        stateFailed(machine);
        return UninstallerError.FileNotFound;
    };

    const files_relative_path = try std.fmt.allocPrint(machine.allocator, "{s}/{s}.files", .{ relative_database_path, pkg_checksum });
    defer machine.allocator.free(files_relative_path);

    removeFromMtree(repo, mtree, files_relative_path, machine.allocator) catch {
        stateFailed(machine);
        return UninstallerError.FileNotFound;
    };

    if (machine.package_file_map) |*file_map| {
        data.freeFileMap(file_map, machine.allocator);
        machine.package_file_map = null;
    }
    if (machine.package_checksum) |checksum| {
        machine.allocator.free(checksum);
        machine.package_checksum = null;
    }

    machine.current_package_index += 1;
    if (machine.current_package_index < machine.data.package_names.len) {
        machine.resetRetries();
        return stateCheckInstalled(machine);
    }

    machine.resetRetries();
    return stateCommit(machine);
}

// Creates a new commit in OSTree representing the system state without the files of this package
fn stateCommit(machine: *UninstallerMachine) anyerror!void {
    try machine.enter(.commit);

    const repo = machine.repo.?;
    const mtree = machine.mtree.?;

    var gerror: ?*c_libs.GError = null;

    const branch_c = try std.fmt.allocPrintZ(machine.allocator, "{s}", .{machine.data.branch});
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

                var should_remove = false;
                for (machine.data.package_names) |name| {
                    if (std.ascii.eqlIgnoreCase(pkg_name, name)) {
                        should_remove = true;
                        break;
                    }
                }
                if (!should_remove) {
                    try body_writer.print("{s}\n", .{trimmed_line});
                }
            }
        } else {
            if (gerror) |err| c_libs.g_error_free(err);
        }
    }

    const body_c = try machine.allocator.dupeZ(u8, body_buf.items);
    defer machine.allocator.free(body_c);

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

        if (c_libs.ostree_repo_prepare_transaction(repo, null, null, &gerror) == 0) {
            if (gerror) |err| c_libs.g_error_free(err);
            stateFailed(machine);
            return UninstallerError.MaxRetriesExceeded;
        }
        return stateCommit(machine);
    }

    var subject_buf = std.ArrayList(u8).init(machine.allocator);
    defer subject_buf.deinit();

    try subject_buf.appendSlice("remove:");

    for (machine.data.package_names, 0..) |name, index| {
        const separator = if (index == 0) " " else ", ";
        try subject_buf.writer().print("{s}{s}", .{ separator, name });
    }

    const subject_c = try machine.allocator.dupeZ(u8, subject_buf.items);
    defer machine.allocator.free(subject_c);

    var commit_checksum: ?[*:0]u8 = null;

    if (c_libs.ostree_repo_write_commit(repo, if (parent_checksum) |checksum| checksum else null, subject_c.ptr, body_c.ptr, null, @ptrCast(mtree_root), &commit_checksum, null, &gerror) == 0) {
        if (gerror) |err| c_libs.g_error_free(err);
        _ = c_libs.ostree_repo_abort_transaction(repo, null, null);
        if (machine.exhausted()) {
            stateFailed(machine);
            return UninstallerError.MaxRetriesExceeded;
        }
        machine.retries += 1;

        if (c_libs.ostree_repo_prepare_transaction(repo, null, null, &gerror) == 0) {
            if (gerror) |err| c_libs.g_error_free(err);
            stateFailed(machine);
            return UninstallerError.MaxRetriesExceeded;
        }
        return stateCommit(machine);
    }

    c_libs.ostree_repo_transaction_set_ref(repo, null, branch_c.ptr, commit_checksum);

    if (c_libs.ostree_repo_commit_transaction(repo, null, null, &gerror) == 0) {
        if (gerror) |err| c_libs.g_error_free(err);
        _ = c_libs.ostree_repo_abort_transaction(repo, null, null);
        if (machine.exhausted()) {
            stateFailed(machine);
            return UninstallerError.MaxRetriesExceeded;
        }
        machine.retries += 1;

        if (c_libs.ostree_repo_prepare_transaction(repo, null, null, &gerror) == 0) {
            if (gerror) |err| c_libs.g_error_free(err);
            stateFailed(machine);
            return UninstallerError.MaxRetriesExceeded;
        }
        return stateCommit(machine);
    }

    machine.commit_checksum = commit_checksum;
    machine.resetRetries();

    return stateCheckoutStaging(machine);
}

fn stateCheckoutStaging(machine: *UninstallerMachine) !void {
    try machine.enter(.checkout_staging);

    const normalized_root_path = if (machine.data.root_path[machine.data.root_path.len - 1] == '/')
        machine.data.root_path[0 .. machine.data.root_path.len - 1]
    else
        machine.data.root_path;

    const staging_path_c = try std.fmt.allocPrintZ(machine.allocator, "{s}/usr-remove-{d}", .{ normalized_root_path, std.time.milliTimestamp() });

    machine.staging_path = staging_path_c;

    var gerror: ?*c_libs.GError = null;
    var options = std.mem.zeroes(c_libs.OstreeRepoCheckoutAtOptions);
    options.mode = c_libs.OSTREE_REPO_CHECKOUT_MODE_NONE;
    options.overwrite_mode = c_libs.OSTREE_REPO_CHECKOUT_OVERWRITE_NONE;

    if (c_libs.ostree_repo_checkout_at(machine.repo.?, &options, std.c.AT.FDCWD, staging_path_c.ptr, machine.commit_checksum.?, null, &gerror) == 0) {
        if (gerror) |err| c_libs.g_error_free(err);
        stateFailed(machine);
        return UninstallerError.MaxRetriesExceeded;
    }

    return stateAtomicSwap(machine);
}

fn stateAtomicSwap(machine: *UninstallerMachine) !void {
    try machine.enter(.atomic_swap);

    const normalized_root_path = if (machine.data.root_path[machine.data.root_path.len - 1] == '/')
        machine.data.root_path[0 .. machine.data.root_path.len - 1]
    else
        machine.data.root_path;

    const staging_path = machine.staging_path.?;

    const usr_path_c = try std.fmt.allocPrintZ(machine.allocator, "{s}/usr", .{normalized_root_path});
    defer machine.allocator.free(usr_path_c);

    const staging_usr_path_c = try std.fmt.allocPrintZ(machine.allocator, "{s}/usr", .{staging_path});
    defer machine.allocator.free(staging_usr_path_c);

    const RENAME_EXCHANGE = 2;
    const AT_FDCWD: isize = -100;
    const result = std.os.linux.syscall5(.renameat2, @bitCast(AT_FDCWD), @intFromPtr(staging_usr_path_c.ptr), @bitCast(AT_FDCWD), @intFromPtr(usr_path_c.ptr), RENAME_EXCHANGE);

    if (std.os.linux.E.init(result) != .SUCCESS) {
        std.fs.deleteTreeAbsolute(staging_path) catch {};
        stateFailed(machine);
        return UninstallerError.MaxRetriesExceeded;
    }

    return stateCleanupStaging(machine);
}

fn stateCleanupStaging(machine: *UninstallerMachine) !void {
    try machine.enter(.cleanup_staging);

    if (machine.staging_path) |staging_path| {
        std.fs.deleteTreeAbsolute(staging_path) catch {};
        machine.allocator.free(staging_path);
        machine.staging_path = null;
    }

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
    // std.debug.print("\n", .{}); // -- Debug information
}

// ── Helpers functions ─────────────────────────────────────────────────────────────────────
// Removes the file entry from the file table of the corresponding directory
fn removeFromMtree(repo: *c_libs.OstreeRepo, root_mtree: *c_libs.OstreeMutableTree, relative_path: []const u8, allocator: std.mem.Allocator) !void {
    var gerror: ?*c_libs.GError = null;

    var path_components = std.ArrayList([]const u8).init(allocator);
    defer path_components.deinit();

    var path_components_iter = std.mem.splitScalar(u8, relative_path, '/');
    while (path_components_iter.next()) |path_part| {
        if (path_part.len > 0) try path_components.append(path_part);
    }
    if (path_components.items.len == 0) return;

    var current_subtree = root_mtree;
    for (path_components.items[0 .. path_components.items.len - 1]) |directory_component| {
        const contents_checksum = c_libs.ostree_mutable_tree_get_contents_checksum(current_subtree);
        const metadata_checksum = c_libs.ostree_mutable_tree_get_metadata_checksum(current_subtree);
        if (contents_checksum != null and metadata_checksum != null) {
            _ = c_libs.ostree_mutable_tree_fill_empty_from_dirtree(current_subtree, repo, contents_checksum, metadata_checksum);
        }

        const directory_component_c = try allocator.dupeZ(u8, directory_component);
        defer allocator.free(directory_component_c);

        var out_file_checksum: [*c]u8 = null;
        var out_subdir: ?*c_libs.OstreeMutableTree = null;

        if (c_libs.ostree_mutable_tree_lookup(current_subtree, directory_component_c.ptr, &out_file_checksum, &out_subdir, &gerror) == 0) {
            if (gerror) |err| c_libs.g_error_free(err);
            return UninstallerError.FileNotFound;
        }
        if (out_subdir == null) return UninstallerError.FileNotFound;
        current_subtree = out_subdir.?;
    }

    const contents_checksum = c_libs.ostree_mutable_tree_get_contents_checksum(current_subtree);
    const metadata_checksum = c_libs.ostree_mutable_tree_get_metadata_checksum(current_subtree);
    if (contents_checksum != null and metadata_checksum != null) {
        _ = c_libs.ostree_mutable_tree_fill_empty_from_dirtree(current_subtree, repo, contents_checksum, metadata_checksum);
    }

    const file_name_c = try allocator.dupeZ(u8, path_components.items[path_components.items.len - 1]);
    defer allocator.free(file_name_c);

    if (c_libs.ostree_mutable_tree_remove(current_subtree, file_name_c.ptr, 0, &gerror) == 0) {
        if (gerror) |err| std.debug.print("ostree_mutable_tree_remove failed for '{s}': {s}\n", .{ file_name_c.ptr, err.*.message });
        if (gerror) |err| c_libs.g_error_free(err);
        return UninstallerError.FileNotFound;
    }
}
