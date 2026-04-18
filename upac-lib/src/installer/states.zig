// ── Imports ─────────────────────────────────────────────────────────────────────
const std = @import("std");

const data = @import("upac-data");

const file = @import("upac-file");
const c_libs = file.c_libs;

const installer_mod = @import("installer.zig");
const InstallerMachine = installer_mod.InstallerMachine;
const InstallerError = installer_mod.InstallerError;

// ── InstallerFSM states ─────────────────────────────────────────────────────────────────
// It verifies the physical existence of the temporary package folder and the repository path. If the paths do not exist, the installation is immediately aborted
pub fn stateVerifying(machine: *InstallerMachine) anyerror!void {
    try machine.enter(.verifying);

    for (machine.data.packages) |entry| {
        std.fs.accessAbsolute(entry.temp_path, .{}) catch {
            stateFailed(machine);
            return InstallerError.PackagePathNotFound;
        };
    }

    std.fs.accessAbsolute(machine.data.repo_path, .{}) catch {
        stateFailed(machine);
        return InstallerError.RepoPathNotFound;
    };

    machine.resetRetries();
    return stateOpenRepo(machine);
}

// Initializes an Ostree Repo object. This marks the transition from Zig paths to objects within the OSTree C library
fn stateOpenRepo(machine: *InstallerMachine) anyerror!void {
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
            return InstallerError.RepoOpenFailed;
        }
        machine.retries += 1;
        return stateOpenRepo(machine);
    }

    machine.repo = repo;

    var transaction_gerror: ?*c_libs.GError = null;
    if (c_libs.ostree_repo_prepare_transaction(repo, null, null, &transaction_gerror) == 0) {
        if (transaction_gerror) |err| c_libs.g_error_free(err);
        stateFailed(machine);
        return InstallerError.RepoOpenFailed;
    }

    const branch_c = std.fmt.allocPrintZ(machine.allocator, "{s}", .{machine.data.branch}) catch |err| {
        stateFailed(machine);
        return err;
    };
    defer machine.allocator.free(branch_c);

    var parent_checksum: ?[*:0]u8 = null;
    _ = c_libs.ostree_repo_resolve_rev(repo, branch_c.ptr, 1, &parent_checksum, null);

    const mtree = if (parent_checksum) |prev_cs| blk: {
        var mtree_gerror: ?*c_libs.GError = null;
        const existing_mtree = c_libs.ostree_mutable_tree_new_from_commit(repo, prev_cs, &mtree_gerror);
        if (existing_mtree) |mt| {
            c_libs.g_free(@ptrCast(prev_cs));
            break :blk mt;
        }
        if (mtree_gerror) |err| c_libs.g_error_free(err);
        c_libs.g_free(@ptrCast(prev_cs));
        break :blk c_libs.ostree_mutable_tree_new();
    } else c_libs.ostree_mutable_tree_new();

    machine.mtree = mtree;

    machine.resetRetries();
    return stateCheckInstalled(machine);
}

// A function to verify that a package has not been previously installed on the system, in order to prevent undefined behavior
fn stateCheckInstalled(machine: *InstallerMachine) anyerror!void {
    try machine.enter(.check_installed);

    const index_path = try std.fmt.allocPrint(machine.allocator, "{s}/index.toml", .{machine.data.database_path});
    defer machine.allocator.free(index_path);

    const index_content = std.fs.cwd().readFileAlloc(machine.allocator, index_path, 16 * 1024 * 1024) catch |err| switch (err) {
        error.FileNotFound => {
            machine.resetRetries();
            return stateWriteDatabase(machine);
        },
        else => return err,
    };
    defer machine.allocator.free(index_content);

    const current_package_name = machine.data.packages[machine.current_package_index].package.meta.name;

    const entry = try data.find(index_content, current_package_name, machine.allocator);
    if (entry != null) {
        stateFailed(machine);
        return InstallerError.AlreadyInstalled;
    }

    machine.resetRetries();
    return stateWriteDatabase(machine);
}

// Once the files have been processed, this function saves the data to the local upac database (.meta and .files) so that the system knows the package is installed
fn stateWriteDatabase(machine: *InstallerMachine) anyerror!void {
    try machine.enter(.write_database);

    const current_install_entry = machine.data.packages[machine.current_package_index];

    const relative_database_path = if (std.mem.startsWith(u8, machine.data.database_path, machine.data.root_path))
        machine.data.database_path[machine.data.root_path.len..]
    else
        machine.data.database_path;

    const staged_database_dir_path = try std.fmt.allocPrint(machine.allocator, "{s}{s}", .{ current_install_entry.temp_path, relative_database_path });
    defer machine.allocator.free(staged_database_dir_path);

    std.fs.cwd().makePath(staged_database_dir_path) catch |err| {
        stateFailed(machine);
        return err;
    };

    var file_map = data.FileMap.init(machine.allocator);
    defer data.freeFileMap(&file_map, machine.allocator);

    collectFileChecksums(machine, current_install_entry.temp_path, current_install_entry.temp_path, &file_map) catch |err| {
        stateFailed(machine);
        return err;
    };

    data.writePackage(staged_database_dir_path, current_install_entry.checksum, current_install_entry.package.meta, file_map, machine.allocator) catch |err| {
        if (machine.exhausted()) {
            stateFailed(machine);
            return err;
        }
        machine.retries += 1;
        return stateWriteDatabase(machine);
    };

    const staged_index_path = try std.fmt.allocPrint(machine.allocator, "{s}/index.toml", .{staged_database_dir_path});
    defer machine.allocator.free(staged_index_path);

    const live_index_path = try std.fmt.allocPrint(machine.allocator, "{s}/index.toml", .{machine.data.database_path});
    defer machine.allocator.free(live_index_path);

    std.fs.copyFileAbsolute(live_index_path, staged_index_path, .{}) catch |err| switch (err) {
        error.FileNotFound => {},
        else => {
            stateFailed(machine);
            return err;
        },
    };

    data.append(staged_index_path, current_install_entry.package.meta.name, current_install_entry.checksum, machine.allocator) catch |err| {
        stateFailed(machine);
        return err;
    };

    machine.resetRetries();
    return stateProcessDbFiles(machine);
}

fn stateProcessDbFiles(machine: *InstallerMachine) anyerror!void {
    try machine.enter(.process_db_files);

    var gerror: ?*c_libs.GError = null;

    const current_install_entry = machine.data.packages[machine.current_package_index];
    const temp_path_c = try std.fmt.allocPrintZ(machine.allocator, "{s}", .{current_install_entry.temp_path});
    defer machine.allocator.free(temp_path_c);

    if (c_libs.ostree_repo_write_dfd_to_mtree(machine.repo.?, std.c.AT.FDCWD, temp_path_c.ptr, machine.mtree.?, null, null, &gerror) == 0) {
        if (gerror) |err| c_libs.g_error_free(err);
        if (machine.exhausted()) {
            stateFailed(machine);
            return InstallerError.RepoOpenFailed;
        }
        machine.retries += 1;
        try machine.resetTransaction();
        return stateProcessDbFiles(machine);
    }

    machine.current_package_index += 1;
    if (machine.current_package_index < machine.data.packages.len) {
        machine.resetRetries();
        return stateCheckInstalled(machine);
    }

    machine.resetRetries();
    return stateCommit(machine);
}

// It takes an in-memory tree (mtree) and uses it to create an actual commit in the selected branch of an OSTree repository
fn stateCommit(machine: *InstallerMachine) anyerror!void {
    try machine.enter(.commit);

    const repo = machine.repo.?;
    const mtree = machine.mtree.?;

    var gerror: ?*c_libs.GError = null;

    const branch_c = try std.fmt.allocPrintZ(machine.allocator, "{s}", .{machine.data.branch});
    defer machine.allocator.free(branch_c);

    const root_path_c = try std.fmt.allocPrintZ(machine.allocator, "{s}", .{machine.data.root_path});
    defer machine.allocator.free(root_path_c);

    var parent_checksum: ?[*:0]u8 = null;
    defer if (parent_checksum) |cs| c_libs.g_free(@ptrCast(cs));
    _ = c_libs.ostree_repo_resolve_rev(repo, branch_c.ptr, 1, &parent_checksum, null);

    var body_buf = std.ArrayList(u8).init(machine.allocator);
    defer body_buf.deinit();
    const body_writer = body_buf.writer();

    if (parent_checksum) |prev_cs| {
        var prev_commit: ?*c_libs.GVariant = null;
        defer if (prev_commit) |v| c_libs.g_variant_unref(v);

        if (c_libs.ostree_repo_load_variant(repo, c_libs.OSTREE_OBJECT_TYPE_COMMIT, prev_cs, &prev_commit, &gerror) != 0) {
            var prev_body_variant: ?*c_libs.GVariant = null;
            defer if (prev_body_variant) |variant| c_libs.g_variant_unref(variant);
            prev_body_variant = c_libs.g_variant_get_child_value(prev_commit, 4);

            var prev_body_len: usize = 0;
            const prev_body_ptr = c_libs.g_variant_get_string(prev_body_variant, &prev_body_len);
            try body_writer.writeAll(prev_body_ptr[0..prev_body_len]);
            if (prev_body_len > 0 and prev_body_ptr[prev_body_len - 1] != '\n')
                try body_writer.writeByte('\n');
        } else {
            if (gerror) |err| c_libs.g_error_free(err);
        }
    }

    for (machine.data.packages) |entry| {
        try body_writer.print("{s} {s}\n", .{ entry.package.meta.name, entry.checksum });
    }

    const body_c = try machine.allocator.dupeZ(u8, body_buf.items);
    defer machine.allocator.free(body_c);

    var mtree_root: ?*c_libs.GFile = null;
    defer if (mtree_root) |root| c_libs.g_object_unref(root);

    if (c_libs.ostree_repo_write_mtree(repo, mtree, &mtree_root, null, &gerror) == 0) {
        if (gerror) |err| c_libs.g_error_free(err);
        if (machine.exhausted()) {
            stateFailed(machine);
            return InstallerError.RepoOpenFailed;
        }
        machine.retries += 1;
        try machine.resetTransaction();
        return stateCommit(machine);
    }

    var subject_buf = std.ArrayList(u8).init(machine.allocator);
    defer subject_buf.deinit();

    try subject_buf.appendSlice("install:");
    for (machine.data.packages, 0..) |entry, index| {
        const separator = if (index == 0) " " else ", ";
        try subject_buf.writer().print("{s}{s} {s}", .{ separator, entry.package.meta.name, entry.package.meta.version });
    }

    const subject_c = try machine.allocator.dupeZ(u8, subject_buf.items);
    defer machine.allocator.free(subject_c);

    var commit_checksum: ?[*:0]u8 = null;
    defer if (commit_checksum) |cs| c_libs.g_free(@ptrCast(cs));

    if (c_libs.ostree_repo_write_commit(repo, if (parent_checksum) |checksum| checksum else null, subject_c.ptr, body_c.ptr, null, @ptrCast(mtree_root), &commit_checksum, null, &gerror) == 0) {
        if (gerror) |err| c_libs.g_error_free(err);
        if (machine.exhausted()) {
            stateFailed(machine);
            return InstallerError.RepoOpenFailed;
        }
        machine.retries += 1;
        try machine.resetTransaction();
        return stateCommit(machine);
    }

    c_libs.ostree_repo_transaction_set_ref(repo, null, branch_c.ptr, commit_checksum);

    if (c_libs.ostree_repo_commit_transaction(repo, null, null, &gerror) == 0) {
        if (gerror) |err| c_libs.g_error_free(err);
        if (machine.exhausted()) {
            stateFailed(machine);
            return InstallerError.RepoOpenFailed;
        }
        machine.retries += 1;
        try machine.resetTransaction();
        return stateCommit(machine);
    }

    var options = std.mem.zeroes(c_libs.OstreeRepoCheckoutAtOptions);
    options.mode = c_libs.OSTREE_REPO_CHECKOUT_MODE_NONE;
    options.overwrite_mode = c_libs.OSTREE_REPO_CHECKOUT_OVERWRITE_UNION_FILES;

    if (c_libs.ostree_repo_checkout_at(repo, &options, std.c.AT.FDCWD, root_path_c.ptr, commit_checksum, null, &gerror) == 0) {
        if (gerror) |err| c_libs.g_error_free(err);
        if (machine.exhausted()) {
            stateFailed(machine);
            return InstallerError.RepoOpenFailed;
        }
        machine.retries += 1;
        try machine.resetTransaction();
        return stateCommit(machine);
    }

    machine.resetRetries();
    return stateDone(machine);
}

// Transitions the machine to its final state. Signals the caller that the package has been successfully committed to OSTree, the database has been updated, and the index has been synchronized
fn stateDone(machine: *InstallerMachine) anyerror!void {
    try machine.enter(.done);
}

// An automaton error state, signaling that a system rollback is required
fn stateFailed(machine: *InstallerMachine) void {
    _ = machine.enter(.failed) catch {};
}

// ── Helpers functions ───────────────────────────────────────────────────
// A recursive assistant. It traverses the directory structure, calculates checksums for all files, and populates the FileMap. It is precisely this data that is subsequently written to the `.files` file within the database
fn collectFileChecksums(machine: *InstallerMachine, dir_path: []const u8, prefix: []const u8, file_map: *data.FileMap) !void {
    var dir = try std.fs.openDirAbsolute(dir_path, .{ .iterate = true });
    defer dir.close();

    var dir_iter = dir.iterate();
    while (try dir_iter.next()) |entry| {
        const entry_path = try std.fs.path.join(
            machine.allocator,
            &.{ dir_path, entry.name },
        );
        defer machine.allocator.free(entry_path);

        switch (entry.kind) {
            .directory => try collectFileChecksums(machine, entry_path, prefix, file_map),
            .file => {
                const entry_path_z = try machine.allocator.dupeZ(u8, entry_path);
                defer machine.allocator.free(entry_path_z);

                var gerror: ?*c_libs.GError = null;
                const gfile = c_libs.g_file_new_for_path(entry_path_z.ptr);
                defer c_libs.g_object_unref(@ptrCast(gfile));

                var raw_checksum_bin: ?[*:0]u8 = null;
                if (c_libs.ostree_checksum_file(gfile, c_libs.OSTREE_OBJECT_TYPE_FILE, &raw_checksum_bin, null, &gerror) == 0) {
                    if (gerror) |err| c_libs.g_error_free(err);
                    continue;
                }
                defer c_libs.g_free(@ptrCast(raw_checksum_bin));

                var hex_checksum_buf: [65]u8 = undefined;
                c_libs.ostree_checksum_inplace_from_bytes(raw_checksum_bin.?, &hex_checksum_buf);

                const relative = entry_path[prefix.len..];
                try file_map.put(
                    try machine.allocator.dupe(u8, relative),
                    try machine.allocator.dupe(u8, hex_checksum_buf[0..64]),
                );
            },
            else => {},
        }
    }
}
