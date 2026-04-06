const std = @import("std");

const data = @import("upac-data");

const file = @import("upac-file");
const c_libs = file.c_libs;

const FileFSM = file.FileFSM;

const installer_mod = @import("installer.zig");
const InstallerMachine = installer_mod.InstallerMachine;
const InstallerError = installer_mod.InstallerError;

// ── Состояния ─────────────────────────────────────────────────────────────────
pub fn stateVerifying(machine: *InstallerMachine) anyerror!void {
    try machine.enter(.verifying);

    std.fs.accessAbsolute(machine.data.package_temp_path, .{}) catch {
        stateFailed(machine);
        return InstallerError.PackagePathNotFound;
    };

    std.fs.accessAbsolute(machine.data.repo_path, .{}) catch {
        stateFailed(machine);
        return InstallerError.RepoPathNotFound;
    };

    machine.resetRetries();
    return stateOpenRepo(machine);
}

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

    const branch_c = std.fmt.allocPrintZ(
        machine.allocator,
        "{s}",
        .{machine.data.branch},
    ) catch |err| {
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
        if (c_libs.ostree_repo_read_commit(repo, checksum, &mtree_root, null, &gerror) != 0) {
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

fn stateCheckInstalled(machine: *InstallerMachine) anyerror!void {
    try machine.enter(.check_installed);

    const branch_c = try std.fmt.allocPrintZ(machine.allocator, "{s}", .{machine.data.branch});
    defer machine.allocator.free(branch_c);

    var last_checksum: ?[*:0]u8 = null;
    if (c_libs.ostree_repo_resolve_rev(machine.repo.?, branch_c.ptr, 1, &last_checksum, null) == 0 or last_checksum == null) {
        machine.resetRetries();
        return stateProcessFiles(machine);
    }
    defer c_libs.g_free(@ptrCast(last_checksum));

    var gerror: ?*c_libs.GError = null;
    var commit_variant: ?*c_libs.GVariant = null;
    defer if (commit_variant) |variant| c_libs.g_variant_unref(variant);

    if (c_libs.ostree_repo_load_variant(machine.repo.?, c_libs.OSTREE_OBJECT_TYPE_COMMIT, last_checksum, &commit_variant, &gerror) == 0) {
        if (gerror) |err| c_libs.g_error_free(err);
        machine.resetRetries();
        return stateProcessFiles(machine);
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

        const separator_index = std.mem.indexOfScalar(u8, trimmed_line, ' ') orelse continue;
        const package_name = trimmed_line[0..separator_index];

        if (std.ascii.eqlIgnoreCase(package_name, machine.data.package_meta.name)) {
            stateFailed(machine);
            return InstallerError.AlreadyInstalled;
        }
    }

    machine.resetRetries();
    return stateProcessFiles(machine);
}

fn stateProcessFiles(machine: *InstallerMachine) anyerror!void {
    try machine.enter(.process_files);

    var dir = std.fs.openDirAbsolute(machine.data.package_temp_path, .{ .iterate = true }) catch |err| {
        if (machine.exhausted()) {
            stateFailed(machine);
            return err;
        }
        machine.retries += 1;
        return stateProcessFiles(machine);
    };
    defer dir.close();

    processDirectory(machine, dir, machine.data.package_temp_path) catch |err| {
        stateFailed(machine);
        return err;
    };

    machine.resetRetries();
    return stateWriteDatabase(machine);
}

fn stateWriteDatabase(machine: *InstallerMachine) anyerror!void {
    try machine.enter(.write_database);

    var file_map = data.FileMap.init(machine.allocator);
    defer data.freeFileMap(&file_map, machine.allocator);

    collectFileChecksums(machine, machine.data.package_temp_path, machine.data.package_temp_path, &file_map) catch |err| {
        stateFailed(machine);
        return err;
    };

    data.write(machine.data.package_temp_path, machine.data.package_checksum, machine.data.package_meta, file_map, machine.allocator) catch |err| {
        if (machine.exhausted()) {
            stateFailed(machine);
            return err;
        }
        machine.retries += 1;
        return stateWriteDatabase(machine);
    };

    machine.resetRetries();
    return stateProcessDbFiles(machine);
}

fn stateProcessDbFiles(machine: *InstallerMachine) anyerror!void {
    try machine.enter(.process_db_files);

    // .meta
    const meta_filename = try std.fmt.allocPrint(machine.allocator, "{s}.meta", .{machine.data.package_checksum});
    defer machine.allocator.free(meta_filename);

    const meta_full_path = try std.fmt.allocPrintZ(machine.allocator, "{s}/{s}", .{ machine.data.package_temp_path, meta_filename });
    defer machine.allocator.free(meta_full_path);

    const meta_checksum = FileFSM.run(.{ .temp_path = meta_full_path, .relative_path = meta_filename, .repo = machine.repo.?, .mtree = machine.mtree.? }, machine.data.max_retries, machine.allocator) catch |err| {
        stateFailed(machine);
        return err;
    };
    machine.allocator.free(meta_checksum);

    const files_filename = try std.fmt.allocPrint(machine.allocator, "{s}.files", .{machine.data.package_checksum});
    defer machine.allocator.free(files_filename);

    const files_full_path = try std.fmt.allocPrintZ(machine.allocator, "{s}/{s}", .{ machine.data.package_temp_path, files_filename });
    defer machine.allocator.free(files_full_path);

    const files_checksum = FileFSM.run(.{ .temp_path = files_full_path, .relative_path = files_filename, .repo = machine.repo.?, .mtree = machine.mtree.? }, machine.data.max_retries, machine.allocator) catch |err| {
        stateFailed(machine);
        return err;
    };
    machine.allocator.free(files_checksum);

    machine.resetRetries();
    return stateCommit(machine);
}

fn stateCommit(machine: *InstallerMachine) anyerror!void {
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

    const checkout_path_c = try std.fmt.allocPrintZ(
        machine.allocator,
        "{s}",
        .{machine.data.checkout_path},
    );
    defer machine.allocator.free(checkout_path_c);

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

    try body_writer.print("{s} {s}\n", .{ machine.data.package_meta.name, machine.data.package_checksum });

    const body_c = try machine.allocator.dupeZ(u8, body_buf.items);
    defer machine.allocator.free(body_c);

    if (c_libs.ostree_repo_prepare_transaction(repo, null, null, &gerror) == 0) {
        if (gerror) |err| c_libs.g_error_free(err);
        if (machine.exhausted()) {
            stateFailed(machine);
            return InstallerError.MaxRetriesExceeded;
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
            return InstallerError.MaxRetriesExceeded;
        }
        machine.retries += 1;
        return stateCommit(machine);
    }

    const subject_c = try std.fmt.allocPrintZ(
        machine.allocator,
        "install: {s} {s}",
        .{ machine.data.package_meta.name, machine.data.package_meta.version },
    );
    defer machine.allocator.free(subject_c);

    var commit_checksum: ?[*:0]u8 = null;
    defer if (commit_checksum) |cs| c_libs.g_free(@ptrCast(cs));

    if (c_libs.ostree_repo_write_commit(repo, if (parent_checksum) |checksum| checksum else null, subject_c.ptr, body_c.ptr, null, @ptrCast(mtree_root), &commit_checksum, null, &gerror) == 0) {
        if (gerror) |err| c_libs.g_error_free(err);
        _ = c_libs.ostree_repo_abort_transaction(repo, null, null);
        if (machine.exhausted()) {
            stateFailed(machine);
            return InstallerError.MaxRetriesExceeded;
        }
        machine.retries += 1;
        return stateCommit(machine);
    }

    c_libs.ostree_repo_transaction_set_ref(repo, null, branch_c.ptr, commit_checksum);

    if (c_libs.ostree_repo_commit_transaction(repo, null, null, &gerror) == 0) {
        if (gerror) |err| c_libs.g_error_free(err);
        if (machine.exhausted()) {
            stateFailed(machine);
            return InstallerError.MaxRetriesExceeded;
        }
        machine.retries += 1;
        return stateCommit(machine);
    }

    var options = std.mem.zeroes(c_libs.OstreeRepoCheckoutAtOptions);
    options.mode = c_libs.OSTREE_REPO_CHECKOUT_MODE_NONE;
    options.overwrite_mode = c_libs.OSTREE_REPO_CHECKOUT_OVERWRITE_UNION_FILES;

    if (c_libs.ostree_repo_checkout_at(repo, &options, std.c.AT.FDCWD, checkout_path_c.ptr, commit_checksum, null, &gerror) == 0) {
        if (gerror) |err| c_libs.g_error_free(err);
        if (machine.exhausted()) {
            stateFailed(machine);
            return InstallerError.MaxRetriesExceeded;
        }
        machine.retries += 1;
        return stateCommit(machine);
    }

    machine.resetRetries();
    return stateDone(machine);
}

fn stateDone(machine: *InstallerMachine) anyerror!void {
    try machine.enter(.done);
}

fn stateFailed(machine: *InstallerMachine) void {
    _ = machine.enter(.failed) catch {};
    std.debug.print("✗ install failed '{s}', states: ", .{
        machine.data.package_meta.name,
    });
    for (machine.stack.items) |state| {
        std.debug.print("{s} ", .{@tagName(state)});
    }
    std.debug.print("\n", .{});
}

// ── Вспомогательные функции ───────────────────────────────────────────────────
fn processDirectory(machine: *InstallerMachine, dir: std.fs.Dir, dir_path: []const u8) !void {
    var dir_iter = dir.iterate();
    while (try dir_iter.next()) |entry| {
        const entry_path = try std.fs.path.join(
            machine.allocator,
            &.{ dir_path, entry.name },
        );
        defer machine.allocator.free(entry_path);

        switch (entry.kind) {
            .directory => {
                var sub_dir = try std.fs.openDirAbsolute(
                    entry_path,
                    .{ .iterate = true },
                );
                defer sub_dir.close();
                try processDirectory(machine, sub_dir, entry_path);
            },
            .file => {
                const entry_path_z = try machine.allocator.dupeZ(u8, entry_path);
                defer machine.allocator.free(entry_path_z);

                var relative = entry_path[machine.data.package_temp_path.len..];
                if (relative.len > 0 and relative[0] == '/') relative = relative[1..];

                const checksum = try FileFSM.run(.{ .temp_path = entry_path_z, .relative_path = relative, .repo = machine.repo.?, .mtree = machine.mtree.? }, machine.data.max_retries, machine.allocator);
                machine.allocator.free(checksum);
            },
            else => {},
        }
    }
}

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

                var raw_checksum: ?[*:0]u8 = null;
                if (c_libs.ostree_checksum_file(gfile, c_libs.OSTREE_OBJECT_TYPE_FILE, &raw_checksum, null, &gerror) == 0) {
                    if (gerror) |err| c_libs.g_error_free(err);
                    continue;
                }
                defer c_libs.g_free(@ptrCast(raw_checksum));

                var relative = entry_path[prefix.len..];
                if (relative.len > 0 and relative[0] == '/') relative = relative[1..];

                try file_map.put(
                    try machine.allocator.dupe(u8, relative),
                    try machine.allocator.dupe(u8, std.mem.span(raw_checksum.?)),
                );
            },
            else => {},
        }
    }
}
