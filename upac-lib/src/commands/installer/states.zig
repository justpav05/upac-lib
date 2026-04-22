// ── Imports ─────────────────────────────────────────────────────────────────────
const std = @import("std");

const data = @import("upac-data");

const file = @import("upac-file");
const c_libs = file.c_libs;

const installer_mod = @import("installer.zig");
const InstallerMachine = installer_mod.InstallerMachine;
const InstallerError = installer_mod.InstallerError;

const dirSize = installer_mod.dirSize;
const collectFileChecksums = installer_mod.collectFileChecksums;

// ── InstallerFSM states ─────────────────────────────────────────────────────────────────
// It verifies the physical existence of the temporary package folder and the repository path. If the paths do not exist, the installation is immediately aborted
pub fn stateVerifying(machine: *InstallerMachine) InstallerError!void {
    machine.enter(.verifying) catch return InstallerError.OutOfMemory;

    for (machine.data.packages) |entry| {
        std.fs.accessAbsolute(entry.temp_path, .{}) catch {
            stateFailed(machine);
            return InstallerError.PathNotFound;
        };
    }

    std.fs.accessAbsolute(machine.data.root_path, .{}) catch {
        stateFailed(machine);
        return InstallerError.PathNotFound;
    };

    std.fs.accessAbsolute(machine.data.repo_path, .{}) catch {
        stateFailed(machine);
        return InstallerError.PathNotFound;
    };

    const prefix_directory = std.fmt.allocPrint(machine.allocator, "{s}/{s}", .{ machine.data.root_path, machine.data.prefix_directory }) catch {
        stateFailed(machine);
        return InstallerError.AllocZFailed;
    };
    defer machine.allocator.free(prefix_directory);

    std.fs.accessAbsolute(prefix_directory, .{}) catch {
        stateFailed(machine);
        return InstallerError.PathNotFound;
    };

    const branch_c = std.fmt.allocPrintZ(machine.allocator, "{s}", .{machine.data.branch}) catch {
        stateFailed(machine);
        return InstallerError.AllocZFailed;
    };

    machine.branch_c = branch_c;

    machine.resetRetries();
    return stateCheckSpace(machine);
}

fn stateCheckSpace(machine: *InstallerMachine) InstallerError!void {
    machine.enter(.check_space) catch return InstallerError.OutOfMemory;

    var required_space: u64 = 0;
    for (machine.data.packages) |entry| {
        required_space += dirSize(machine.allocator, entry.temp_path) catch {
            stateFailed(machine);
            return InstallerError.CheckSpaceFailed;
        };
    }

    const root_path_c = std.fmt.allocPrintZ(machine.allocator, "{s}", .{machine.data.root_path}) catch {
        stateFailed(machine);
        return InstallerError.AllocZFailed;
    };
    defer machine.allocator.free(root_path_c);

    var root_path_stat: c_libs.struct_statvfs = undefined;
    if (c_libs.statvfs(root_path_c.ptr, &root_path_stat) != 0) {
        stateFailed(machine);
        return InstallerError.CheckSpaceFailed;
    }

    const available_space: u64 = @as(u64, @intCast(root_path_stat.f_bavail)) * @as(u64, @intCast(root_path_stat.f_bsize));
    if (required_space > available_space) {
        stateFailed(machine);
        return InstallerError.NotEnoughSpace;
    }

    machine.resetRetries();
    return stateOpenRepo(machine);
}

// Initializes an Ostree Repo object. This marks the transition from Zig paths to objects within the OSTree C library
fn stateOpenRepo(machine: *InstallerMachine) InstallerError!void {
    machine.enter(.open_repo) catch return InstallerError.OutOfMemory;

    const repo_path_c = std.fmt.allocPrintZ(machine.allocator, "{s}", .{machine.data.repo_path}) catch {
        stateFailed(machine);
        return InstallerError.AllocZFailed;
    };
    defer machine.allocator.free(repo_path_c);

    const gfile = c_libs.g_file_new_for_path(repo_path_c.ptr);
    defer c_libs.g_object_unref(@ptrCast(gfile));

    const repo = c_libs.ostree_repo_new(gfile);

    if (c_libs.ostree_repo_open(repo, machine.cancellable, &machine.gerror) == 0) {
        c_libs.g_object_unref(repo);
        return machine.retry(stateOpenRepo);
    }

    machine.repo = repo;

    if (c_libs.ostree_repo_prepare_transaction(repo, null, machine.cancellable, &machine.gerror) == 0) {
        stateFailed(machine);
        return InstallerError.RepoTransactionFailed;
    }

    const branch_c = machine.branch_c orelse {
        stateFailed(machine);
        return InstallerError.AllocZFailed;
    };

    var previos_mtree: ?*c_libs.OstreeMutableTree = null;
    if (c_libs.ostree_repo_resolve_rev(repo, branch_c, 0, &machine.previous_commit_checksum, null) != 0) {
        previos_mtree = c_libs.ostree_mutable_tree_new_from_commit(repo, machine.previous_commit_checksum, &machine.gerror);
        if (previos_mtree == null) {
            if (machine.gerror != null) {
                stateFailed(machine);
                return InstallerError.RepoTransactionFailed;
            }
            previos_mtree = c_libs.ostree_mutable_tree_new();
        }
    } else {
        previos_mtree = c_libs.ostree_mutable_tree_new();
    }

    machine.mtree = previos_mtree;

    machine.resetRetries();
    return stateCheckInstalled(machine);
}

// A function to verify that a package has not been previously installed on the system, in order to prevent undefined behavior
fn stateCheckInstalled(machine: *InstallerMachine) InstallerError!void {
    machine.enter(.check_installed) catch return InstallerError.OutOfMemory;

    var gerror: ?*c_libs.GError = null;
    defer if (gerror) |err| c_libs.g_error_free(err);

    const previous_commit_checksum = machine.previous_commit_checksum orelse {
        machine.resetRetries();
        return stateWriteDatabase(machine);
    };

    var commit_variant: ?*c_libs.GVariant = null;
    defer if (commit_variant) |variant| c_libs.g_variant_unref(variant);

    if (c_libs.ostree_repo_load_variant(machine.repo.?, c_libs.OSTREE_OBJECT_TYPE_COMMIT, previous_commit_checksum, &commit_variant, &gerror) == 0) {
        machine.resetRetries();
        return stateWriteDatabase(machine);
    }

    var body_variant: ?*c_libs.GVariant = null;
    defer if (body_variant) |variant| c_libs.g_variant_unref(variant);

    body_variant = c_libs.g_variant_get_child_value(commit_variant, 4);

    var body_len: usize = 0;
    const body_ptr = c_libs.g_variant_get_string(body_variant, &body_len);
    const body = body_ptr[0..body_len];

    const current_package_name = machine.data.packages[machine.current_package_index].package.meta.name;

    var split_lines_iter = std.mem.splitScalar(u8, body, '\n');
    while (split_lines_iter.next()) |line| {
        const trimmed_line = std.mem.trim(u8, line, " \t\r");
        if (trimmed_line.len == 0) continue;

        const separator_index = std.mem.indexOfScalar(u8, trimmed_line, ' ') orelse continue;
        const installed_package_name = trimmed_line[0..separator_index];

        if (std.ascii.eqlIgnoreCase(installed_package_name, current_package_name)) {
            stateFailed(machine);
            return InstallerError.AlreadyInstalled;
        }
    }

    machine.resetRetries();
    return stateWriteDatabase(machine);
}

// Once the files have been processed, this function saves the data to the local upac database (.meta and .files) so that the system knows the package is installed
fn stateWriteDatabase(machine: *InstallerMachine) InstallerError!void {
    machine.enter(.write_database) catch return InstallerError.OutOfMemory;

    const current_install_entry = machine.data.packages[machine.current_package_index];

    const relative_database_path = if (std.mem.startsWith(u8, machine.data.database_path, machine.data.root_path))
        machine.data.database_path[machine.data.root_path.len..]
    else
        machine.data.database_path;

    const staged_database_dir_path = std.fmt.allocPrint(machine.allocator, "{s}{s}", .{ current_install_entry.temp_path, relative_database_path }) catch return InstallerError.AllocZFailed;
    defer machine.allocator.free(staged_database_dir_path);

    std.fs.cwd().makePath(staged_database_dir_path) catch {
        stateFailed(machine);
        return InstallerError.MakeFailed;
    };

    var file_map = data.FileMap.init(machine.allocator);
    defer data.freeFileMap(&file_map, machine.allocator);

    collectFileChecksums(machine, current_install_entry.temp_path, current_install_entry.temp_path, &file_map) catch {
        stateFailed(machine);
        return InstallerError.CollectFileChecksumsFailed;
    };

    data.writePackage(staged_database_dir_path, current_install_entry.checksum, current_install_entry.package.meta, file_map, machine.allocator) catch return machine.retry(stateWriteDatabase);

    machine.resetRetries();
    return stateProcessDbFiles(machine);
}

fn stateProcessDbFiles(machine: *InstallerMachine) InstallerError!void {
    machine.enter(.process_db_files) catch return InstallerError.OutOfMemory;

    const current_install_entry = machine.data.packages[machine.current_package_index];

    const temp_path_c = try std.fmt.allocPrintZ(machine.allocator, "{s}", .{current_install_entry.temp_path});
    defer machine.allocator.free(temp_path_c);

    if (c_libs.ostree_repo_write_dfd_to_mtree(machine.repo.?, std.c.AT.FDCWD, temp_path_c.ptr, machine.mtree.?, null, machine.cancellable, &machine.gerror) == 0) return machine.retry(stateProcessDbFiles);

    machine.current_package_index += 1;
    if (machine.current_package_index < machine.data.packages.len) {
        machine.resetRetries();
        return stateCheckInstalled(machine);
    }

    machine.resetRetries();
    return stateCommit(machine);
}

// It takes an in-memory tree (mtree) and uses it to create an actual commit in the selected branch of an OSTree repository
fn stateCommit(machine: *InstallerMachine) InstallerError!void {
    machine.enter(.commit) catch return InstallerError.OutOfMemory;

    const repo = machine.repo orelse {
        stateFailed(machine);
        return InstallerError.RepoOpenFailed;
    };
    const mtree = machine.mtree orelse {
        stateFailed(machine);
        return InstallerError.PackageNotFound;
    };

    const branch_c = machine.branch_c orelse {
        stateFailed(machine);
        return InstallerError.PackageNotFound;
    };

    const root_path_c = try std.fmt.allocPrintZ(machine.allocator, "{s}", .{machine.data.root_path});
    defer machine.allocator.free(root_path_c);

    var body_buf = std.ArrayList(u8).init(machine.allocator);
    defer body_buf.deinit();

    const body_writer = body_buf.writer();
    if (machine.previous_commit_checksum) |checksum| {
        var previous_commit: ?*c_libs.GVariant = null;
        defer if (previous_commit) |variant| c_libs.g_variant_unref(variant);

        if (c_libs.ostree_repo_load_variant(machine.repo.?, c_libs.OSTREE_OBJECT_TYPE_COMMIT, checksum, &previous_commit, &machine.gerror) != 0) {
            var prev_body_variant: ?*c_libs.GVariant = null;
            defer if (prev_body_variant) |variant| c_libs.g_variant_unref(variant);

            prev_body_variant = c_libs.g_variant_get_child_value(previous_commit, 4);

            var prev_body_len: usize = 0;
            const prev_body_ptr = c_libs.g_variant_get_string(prev_body_variant, &prev_body_len);

            try body_writer.writeAll(prev_body_ptr[0..prev_body_len]);
            if (prev_body_len > 0 and prev_body_ptr[prev_body_len - 1] != '\n') try body_writer.writeByte('\n');
        }
    }

    for (machine.data.packages) |entry| try body_writer.print("{s} {s}\n", .{ entry.package.meta.name, entry.checksum });

    const body_c = try machine.allocator.dupeZ(u8, body_buf.items);
    defer machine.allocator.free(body_c);

    var mtree_root: ?*c_libs.GFile = null;
    defer if (mtree_root) |root| c_libs.g_object_unref(root);

    if (c_libs.ostree_repo_write_mtree(repo, mtree, &mtree_root, machine.cancellable, &machine.gerror) == 0) return machine.retry(stateCommit);

    var subject_buf = std.ArrayList(u8).init(machine.allocator);
    defer subject_buf.deinit();

    try subject_buf.appendSlice("install:");
    for (machine.data.packages, 0..) |entry, index| {
        const separator = if (index == 0) " " else ", ";
        try subject_buf.writer().print("{s}{s} {s}", .{ separator, entry.package.meta.name, entry.package.meta.version });
    }

    const subject_c = try machine.allocator.dupeZ(u8, subject_buf.items);
    defer machine.allocator.free(subject_c);

    if (c_libs.ostree_repo_write_commit(repo, if (machine.previous_commit_checksum) |checksum| checksum else null, subject_c.ptr, body_c.ptr, null, @ptrCast(mtree_root), @ptrCast(&machine.commit_checksum), machine.cancellable, &machine.gerror) == 0) return machine.retry(stateCommit);

    c_libs.ostree_repo_transaction_set_ref(repo, null, branch_c, machine.commit_checksum.?);

    if (c_libs.ostree_repo_commit_transaction(repo, null, machine.cancellable, &machine.gerror) == 0) return machine.retry(stateCommit);

    machine.resetRetries();
    return stateCheckout(machine);
}

// Checks out the committed tree into a temporary staging directory, then atomically swaps it with the real target using renameat2(RENAME_EXCHANGE)
fn stateCheckout(machine: *InstallerMachine) InstallerError!void {
    machine.enter(.checkout) catch return InstallerError.OutOfMemory;

    const repo = machine.repo orelse return stateFailed(machine);

    const timestamp = std.time.milliTimestamp();
    const staging_path_c = std.fmt.allocPrintZ(machine.allocator, "{s}/{s}-installing-{d}", .{ machine.data.root_path, machine.data.prefix_directory, timestamp }) catch {
        stateFailed(machine);
        return InstallerError.AllocZFailed;
    };
    machine.staging_path = staging_path_c;

    var options = std.mem.zeroes(c_libs.OstreeRepoCheckoutAtOptions);
    options.mode = c_libs.OSTREE_REPO_CHECKOUT_MODE_NONE;
    options.overwrite_mode = c_libs.OSTREE_REPO_CHECKOUT_OVERWRITE_UNION_FILES;

    if (c_libs.ostree_repo_checkout_at(repo, &options, std.c.AT.FDCWD, staging_path_c.ptr, machine.commit_checksum.?, machine.cancellable, &machine.gerror) == 0) {
        std.fs.deleteTreeAbsolute(staging_path_c) catch {
            stateFailed(machine);
            return InstallerError.CheckoutFailed;
        };
        machine.allocator.free(staging_path_c);
        machine.staging_path = null;

        if (machine.exhausted()) {
            stateFailed(machine);
            return InstallerError.CheckoutFailed;
        }
        machine.retries += 1;
        return stateCheckout(machine);
    }

    machine.resetRetries();
    return stateAtomicSwap(machine);
}

fn stateAtomicSwap(machine: *InstallerMachine) InstallerError!void {
    machine.enter(.atomic_swap) catch return InstallerError.OutOfMemory;

    const staging_path = machine.staging_path orelse {
        stateFailed(machine);
        return InstallerError.CheckoutFailed;
    };

    const staging_usr_path_c = std.fmt.allocPrintZ(machine.allocator, "{s}/{s}", .{ staging_path, machine.data.prefix_directory }) catch {
        stateFailed(machine);
        return InstallerError.AllocZFailed;
    };
    defer machine.allocator.free(staging_usr_path_c);

    const root_usr_path_c = std.fmt.allocPrintZ(machine.allocator, "{s}/{s}", .{ machine.data.root_path, machine.data.prefix_directory }) catch {
        stateFailed(machine);
        return InstallerError.AllocZFailed;
    };
    defer machine.allocator.free(root_usr_path_c);

    const result = std.os.linux.syscall5(.renameat2, @bitCast(@as(isize, std.os.linux.AT.FDCWD)), @intFromPtr(staging_usr_path_c.ptr), @bitCast(@as(isize, std.os.linux.AT.FDCWD)), @intFromPtr(root_usr_path_c.ptr), 2);

    if (std.os.linux.E.init(result) != .SUCCESS) {
        std.fs.deleteTreeAbsolute(staging_path) catch {
            stateFailed(machine);
            return InstallerError.CheckoutFailed;
        };
        stateFailed(machine);
        return InstallerError.CheckoutFailed;
    }

    machine.resetRetries();
    return stateCleanupStaging(machine);
}

fn stateCleanupStaging(machine: *InstallerMachine) InstallerError!void {
    machine.enter(.cleanup) catch return InstallerError.OutOfMemory;

    if (machine.staging_path) |staging_path| {
        std.fs.deleteTreeAbsolute(staging_path) catch {
            stateFailed(machine);
            return InstallerError.CheckoutFailed;
        };
        machine.allocator.free(staging_path);
        machine.staging_path = null;
    }

    return stateDone(machine);
}

// Transitions the machine to its final state. Signals the caller that the package has been successfully committed to OSTree, the database has been updated, and the index has been synchronized
fn stateDone(machine: *InstallerMachine) InstallerError!void {
    machine.enter(.done) catch return InstallerError.OutOfMemory;
}

// An automaton error state, signaling that a system rollback is required
pub fn stateFailed(machine: *InstallerMachine) void {
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
            _ = c_libs.ostree_repo_set_ref_immediate(repo, null, branch_c, null, null, null);
        }
    }

    _ = machine.enter(.failed) catch {};
}
