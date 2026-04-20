// ── Imports ─────────────────────────────────────────────────────────────────────
const std = @import("std");

const data = @import("upac-data");

const file = @import("upac-file");
const c_libs = file.c_libs;

const uninstaller = @import("uninstaller.zig");
const UninstallerMachine = uninstaller.UninstallerMachine;
const UninstallerError = uninstaller.UninstallerError;

const removeFromMtree = uninstaller.removeFromMtree;

// ── States ─────────────────────────────────────────────────────────────────────
// The status of the path validation check
pub fn stateVerifying(machine: *UninstallerMachine) UninstallerError!void {
    try machine.enter(.verifying);

    std.fs.accessAbsolute(machine.data.root_path, .{}) catch {
        stateFailed(machine);
        return UninstallerError.PathNotFound;
    };

    std.fs.accessAbsolute(machine.data.repo_path, .{}) catch {
        stateFailed(machine);
        return UninstallerError.PathNotFound;
    };

    const prefix_directory = std.fmt.allocPrint(machine.allocator, "{s}/{s}", .{ machine.data.root_path, machine.data.prefix_directory }) catch {
        stateFailed(machine);
        return UninstallerError.AllocZFailed;
    };
    defer machine.allocator.free(prefix_directory);

    std.fs.accessAbsolute(prefix_directory, .{}) catch {
        stateFailed(machine);
        return UninstallerError.PathNotFound;
    };

    const branch_c = std.fmt.allocPrintZ(machine.allocator, "{s}", .{machine.data.branch}) catch {
        stateFailed(machine);
        return UninstallerError.AllocZFailed;
    };

    machine.branch_c = branch_c;

    machine.resetRetries();
    return stateOpenRepo(machine);
}

// The state of opening the repository and writing its data to the machine
fn stateOpenRepo(machine: *UninstallerMachine) UninstallerError!void {
    machine.enter(.open_repo) catch return UninstallerError.OutOfMemory;

    const repo_path_c = std.fmt.allocPrintZ(machine.allocator, "{s}", .{machine.data.repo_path}) catch {
        stateFailed(machine);
        return UninstallerError.AllocZFailed;
    };
    defer machine.allocator.free(repo_path_c);

    const gfile = c_libs.g_file_new_for_path(repo_path_c.ptr);
    defer c_libs.g_object_unref(@ptrCast(gfile));

    const repo = c_libs.ostree_repo_new(gfile);

    if (c_libs.ostree_repo_open(repo, null, &machine.gerror) == 0) {
        c_libs.g_object_unref(repo);
        return machine.retry(stateOpenRepo);
    }

    machine.repo = repo;

    if (c_libs.ostree_repo_prepare_transaction(repo, null, null, &machine.gerror) == 0) {
        stateFailed(machine);
        return UninstallerError.RepoTransactionFailed;
    }

    const branch_c = machine.branch_c orelse return UninstallerError.AllocZFailed;

    var previos_mtree: ?*c_libs.OstreeMutableTree = null;
    if (c_libs.ostree_repo_resolve_rev(repo, branch_c, 0, &machine.previous_commit_checksum, null) != 0) {
        if (c_libs.ostree_mutable_tree_new_from_commit(repo, machine.previous_commit_checksum, &machine.gerror)) |mtree| {
            previos_mtree = mtree;
        }
    } else {
        previos_mtree = c_libs.ostree_mutable_tree_new();
    }

    if (machine.mtree) |mtree| c_libs.g_object_unref(mtree);
    machine.mtree = previos_mtree;

    machine.resetRetries();
    return stateCheckInstalled(machine);
}

// Installation verification status, designed to prevent the removal of non-existent items
fn stateCheckInstalled(machine: *UninstallerMachine) UninstallerError!void {
    try machine.enter(.check_installed);

    const repo = machine.repo orelse return UninstallerError.RepoOpenFailed;

    const last_checksum = machine.previous_commit_checksum orelse return UninstallerError.PackageNotFound;

    var commit_variant: ?*c_libs.GVariant = null;
    defer if (commit_variant) |variant| c_libs.g_variant_unref(variant);

    if (c_libs.ostree_repo_load_variant(repo, c_libs.OSTREE_OBJECT_TYPE_COMMIT, last_checksum, &commit_variant, &machine.gerror) == 0) {
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
fn stateLoadFiles(machine: *UninstallerMachine) UninstallerError!void {
    try machine.enter(.load_files);

    const package_checksum = machine.package_checksum orelse {
        stateFailed(machine);
        return UninstallerError.PackageNotFound;
    };

    const file_map = data.readFiles(machine.data.db_path, package_checksum, machine.allocator) catch {
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
            return machine.retry(stateRemoveFiles);
        };
    }

    machine.resetRetries();
    return stateRemoveDbFiles(machine);
}

// The state of removal from the global index, as well as of files belonging to the package in the database
fn stateRemoveDbFiles(machine: *UninstallerMachine) UninstallerError!void {
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
        return UninstallerError.PackageNotFound;
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
fn stateCommit(machine: *UninstallerMachine) UninstallerError!void {
    try machine.enter(.commit);

    const repo = machine.repo.?;
    const mtree = machine.mtree.?;

    const branch_c = machine.branch_c orelse return UninstallerError.AllocZFailed;

    const root_path_c = try std.fmt.allocPrintZ(machine.allocator, "{s}", .{machine.data.root_path});
    defer machine.allocator.free(root_path_c);

    var body_buf = std.ArrayList(u8).init(machine.allocator);
    defer body_buf.deinit();
    const body_writer = body_buf.writer();

    if (machine.previous_commit_checksum) |prev_checksum| {
        var prev_commit_variant: ?*c_libs.GVariant = null;
        defer if (prev_commit_variant) |variant| c_libs.g_variant_unref(variant);

        if (c_libs.ostree_repo_load_variant(repo, c_libs.OSTREE_OBJECT_TYPE_COMMIT, prev_checksum, &prev_commit_variant, &machine.gerror) != 0) {
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
        }
    }

    const body_c = try machine.allocator.dupeZ(u8, body_buf.items);
    defer machine.allocator.free(body_c);

    var out_g_file: ?*c_libs.GFile = null;
    defer if (out_g_file) |out_file| c_libs.g_object_unref(@ptrCast(out_file));
    if (c_libs.ostree_repo_write_mtree(repo, mtree, &out_g_file, null, &machine.gerror) == 0) return machine.retry(stateCommit);

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
    if (c_libs.ostree_repo_write_commit(repo, if (machine.previous_commit_checksum) |checksum| checksum else null, subject_c.ptr, body_c.ptr, null, @as(?*c_libs.OstreeRepoFile, @ptrCast(out_g_file)), &commit_checksum, null, &machine.gerror) == 0) return machine.retry(stateCommit);

    c_libs.ostree_repo_transaction_set_ref(repo, null, branch_c, commit_checksum);

    if (c_libs.ostree_repo_commit_transaction(repo, null, null, &machine.gerror) == 0) return machine.retry(stateCommit);

    machine.commit_checksum = commit_checksum;
    machine.resetRetries();

    return stateCheckoutStaging(machine);
}

fn stateCheckoutStaging(machine: *UninstallerMachine) UninstallerError!void {
    try machine.enter(.checkout_staging);

    const normalized_root_path = if (machine.data.root_path[machine.data.root_path.len - 1] == '/')
        machine.data.root_path[0 .. machine.data.root_path.len - 1]
    else
        machine.data.root_path;

    const staging_path_c = try std.fmt.allocPrintZ(machine.allocator, "{s}/{s}-remove-{d}", .{ normalized_root_path, machine.data.prefix_directory, std.time.milliTimestamp() });

    machine.staging_path = staging_path_c;

    var options = std.mem.zeroes(c_libs.OstreeRepoCheckoutAtOptions);
    options.mode = c_libs.OSTREE_REPO_CHECKOUT_MODE_NONE;
    options.overwrite_mode = c_libs.OSTREE_REPO_CHECKOUT_OVERWRITE_NONE;

    if (c_libs.ostree_repo_checkout_at(machine.repo.?, &options, std.c.AT.FDCWD, staging_path_c.ptr, machine.commit_checksum.?, null, &machine.gerror) == 0) {
        machine.staging_path = null;
        stateFailed(machine);
        std.fs.deleteTreeAbsolute(staging_path_c) catch {
            return UninstallerError.MaxRetriesExceeded;
        };
        return UninstallerError.CheckoutFailed;
    }

    return stateAtomicSwap(machine);
}

fn stateAtomicSwap(machine: *UninstallerMachine) UninstallerError!void {
    try machine.enter(.atomic_swap);

    const normalized_root_path = if (machine.data.root_path[machine.data.root_path.len - 1] == '/')
        machine.data.root_path[0 .. machine.data.root_path.len - 1]
    else
        machine.data.root_path;

    const staging_path = machine.staging_path.?;

    const prefix_path_c = try std.fmt.allocPrintZ(machine.allocator, "{s}/{s}", .{ normalized_root_path, machine.data.prefix_directory });
    defer machine.allocator.free(prefix_path_c);

    const staging_prefix_path_c = try std.fmt.allocPrintZ(machine.allocator, "{s}/{s}", .{ staging_path, machine.data.prefix_directory });
    defer machine.allocator.free(staging_prefix_path_c);

    const result = std.os.linux.syscall5(.renameat2, @bitCast(@as(isize, std.os.linux.AT.FDCWD)), @intFromPtr(staging_prefix_path_c.ptr), @bitCast(@as(isize, std.os.linux.AT.FDCWD)), @intFromPtr(prefix_path_c.ptr), 2);

    if (std.os.linux.E.init(result) != .SUCCESS) {
        stateFailed(machine);
        std.fs.deleteTreeAbsolute(staging_path) catch {
            return UninstallerError.MaxRetriesExceeded;
        };
        return UninstallerError.CheckoutFailed;
    }

    return stateCleanupStaging(machine);
}

fn stateCleanupStaging(machine: *UninstallerMachine) UninstallerError!void {
    try machine.enter(.cleanup_staging);

    if (machine.staging_path) |staging_path| {
        std.fs.deleteTreeAbsolute(staging_path) catch {
            stateFailed(machine);
            return UninstallerError.CheckoutFailed;
        };
    }

    return stateDone(machine);
}

// State of successful completion of the package removal process and deployment of the new commit
fn stateDone(machine: *UninstallerMachine) UninstallerError!void {
    try machine.enter(.done);
}

// A state of unsuccessful package removal, signaling the system that a rollback is required to revert the changes
pub fn stateFailed(machine: *UninstallerMachine) void {
    const branch_c = machine.branch_c orelse {
        _ = machine.enter(.failed) catch {};
        return;
    };

    if (machine.staging_path) |staging| {
        std.fs.deleteTreeAbsolute(staging) catch {};
        machine.allocator.free(staging);
        machine.staging_path = null;
    }

    if (machine.repo) |repo| {
        _ = c_libs.ostree_repo_abort_transaction(repo, null, &machine.gerror);

        if (machine.commit_checksum != null) {
            _ = c_libs.ostree_repo_set_ref_immediate(repo, null, branch_c, machine.previous_commit_checksum, null, null);
        }
    }

    _ = machine.enter(.failed) catch {};
}
