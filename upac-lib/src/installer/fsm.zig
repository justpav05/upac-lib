const std = @import("std");
const posix = std.posix;

const database = @import("upac-database");
const PackageFiles = database.PackageFiles;

const installer = @import("installer.zig");
const InstallerMachine = installer.InstallerMachine;
const StateId = installer.StateId;
const InstallData = installer.InstallData;

// ── Состояния ─────────────────────────────────────────────────────────────────
pub fn stateVerifying(machine: *InstallerMachine) anyerror!void {
    try machine.enter(.verifying);

    std.fs.accessAbsolute(machine.data.package_path, .{}) catch |err| {
        stateFailed(machine);
        return err;
    };

    std.fs.accessAbsolute(machine.data.repo_path, .{}) catch |err| {
        stateFailed(machine);
        return err;
    };

    machine.resetRetries();
    return stateCopying(machine);
}

pub fn stateCopying(machine: *InstallerMachine) anyerror!void {
    try machine.enter(.copying);

    const package_destination = try std.fs.path.join(
        machine.allocator,
        &.{ machine.data.repo_path, machine.data.package_meta.name },
    );
    defer machine.allocator.free(package_destination);

    std.fs.makeDirAbsolute(package_destination) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    var package_dir = std.fs.openDirAbsolute(machine.data.package_path, .{ .iterate = true }) catch |err| {
        if (machine.exhausted()) {
            stateFailed(machine);
            return err;
        }
        machine.retries += 1;
        return stateCopying(machine);
    };
    defer package_dir.close();

    copyTree(machine.allocator, package_dir, machine.data.package_path, package_destination) catch |err| {
        if (machine.exhausted()) {
            stateFailed(machine);
            return err;
        }
        machine.retries += 1;
        return stateCopying(machine);
    };

    machine.resetRetries();
    return stateLinking(machine);
}

pub fn stateLinking(machine: *InstallerMachine) anyerror!void {
    try machine.enter(.linking);

    const package_repo_path = try std.fs.path.join(
        machine.allocator,
        &.{ machine.data.repo_path, machine.data.package_meta.name },
    );
    defer machine.allocator.free(package_repo_path);

    hardlinkTree(machine.allocator, package_repo_path, machine.data.root_path) catch |err| {
        if (err == error.FileNotFound) {
            machine.resetRetries();
            return stateCopying(machine);
        } else if (machine.exhausted()) {
            stateFailed(machine);
            return err;
        } else {
            machine.retries += 1;
            return stateLinking(machine);
        }
    };

    machine.resetRetries();
    return stateSettingPerms(machine);
}

pub fn stateSettingPerms(machine: *InstallerMachine) anyerror!void {
    try machine.enter(.setting_perms);

    // var root_dir = std.fs.openDirAbsolute(machine.state.root_path, .{ .iterate = true }) catch |err| {
    //     if (machine.exhausted()) {
    //         stateFailed(machine);
    //         return err;
    //     }
    //     machine.retries += 1;
    //     return stateLinking(machine);
    // };
    // defer root_dir.close();

    const pkg_path = try std.fs.path.join(
        machine.allocator,
        &.{ machine.data.repo_path, machine.data.package_meta.name },
    );
    defer machine.allocator.free(pkg_path);

    setPermsTree(machine.allocator, pkg_path) catch |err| switch (err) {
        error.FileNotFound => {
            machine.resetRetries();
            return stateLinking(machine);
        },
        else => {
            if (machine.exhausted()) {
                stateFailed(machine);
                return err;
            }
            machine.retries += 1;
            return stateSettingPerms(machine);
        },
    };

    machine.resetRetries();
    return stateRegistering(machine);
}

pub fn stateRegistering(machine: *InstallerMachine) anyerror!void {
    try machine.enter(.registering);

    var files_list = std.ArrayList([]const u8).init(machine.allocator);
    defer {
        for (files_list.items) |file| machine.allocator.free(file);
        files_list.deinit();
    }

    const package_root = try std.fs.path.join(
        machine.allocator,
        &.{ machine.data.repo_path, machine.data.package_meta.name },
    );
    defer machine.allocator.free(package_root);

    collectFiles(machine.allocator, package_root, &files_list) catch |err| {
        if (machine.exhausted()) {
            stateFailed(machine);
            return err;
        }
        machine.retries += 1;
        return stateRegistering(machine);
    };

    const paths_copy = try machine.allocator.dupe([]const u8, files_list.items);
    defer machine.allocator.free(paths_copy);

    const pkg_files = PackageFiles{
        .name = machine.data.package_meta.name,
        .paths = paths_copy,
    };

    database.addPackage(machine.data.database_path, machine.data.package_meta, pkg_files, machine.allocator) catch |err| {
        if (machine.exhausted()) {
            stateFailed(machine);
            return err;
        }
        machine.retries += 1;
        return stateRegistering(machine);
    };

    machine.resetRetries();
    return stateDone(machine);
}

pub fn stateDone(machine: *InstallerMachine) anyerror!void {
    try machine.enter(.done);
}

pub fn stateFailed(machine: *InstallerMachine) void {
    _ = machine.enter(.failed) catch {};
    std.debug.print("✗ install failed '{s}', path: ", .{machine.data.package_meta.name});
    for (machine.stack.items) |state| std.debug.print("{s} ", .{@tagName(state)});
    std.debug.print("\n", .{});
}

// ── Вспомогательные функции ───────────────────────────────────────────────────
fn copyTree(allocator: std.mem.Allocator, source_dir: std.fs.Dir, source_path: []const u8, destination_path: []const u8) !void {
    var source_dir_iter = source_dir.iterate();
    while (try source_dir_iter.next()) |entry| {
        const source_entry_with_name = try std.fs.path.join(allocator, &.{ source_path, entry.name });
        defer allocator.free(source_entry_with_name);

        const destination_entry_with_name = try std.fs.path.join(allocator, &.{ destination_path, entry.name });
        defer allocator.free(destination_entry_with_name);

        switch (entry.kind) {
            .directory => {
                std.fs.makeDirAbsolute(destination_entry_with_name) catch |err| switch (err) {
                    error.PathAlreadyExists => {},
                    else => return err,
                };

                var sub_dir = try std.fs.openDirAbsolute(source_entry_with_name, .{ .iterate = true });
                defer sub_dir.close();

                try copyTree(allocator, sub_dir, source_entry_with_name, destination_entry_with_name);
            },
            .file => {
                try std.fs.copyFileAbsolute(source_entry_with_name, destination_entry_with_name, .{});
            },
            else => {},
        }
    }
}

fn hardlinkTree(allocator: std.mem.Allocator, source_path: []const u8, destination_path: []const u8) !void {
    var source_dir = try std.fs.openDirAbsolute(source_path, .{ .iterate = true });
    defer source_dir.close();

    var source_dir_iter = source_dir.iterate();
    while (try source_dir_iter.next()) |entry| {
        const source_path_with_name = try std.fs.path.join(allocator, &.{ source_path, entry.name });
        defer allocator.free(source_path_with_name);

        const destination_path_with_name = try std.fs.path.join(allocator, &.{ destination_path, entry.name });
        defer allocator.free(destination_path_with_name);

        switch (entry.kind) {
            .directory => {
                std.fs.makeDirAbsolute(destination_path_with_name) catch |err| switch (err) {
                    error.PathAlreadyExists => {},
                    else => return err,
                };
                try hardlinkTree(allocator, source_path_with_name, destination_path_with_name);
            },
            .file => {
                std.fs.deleteFileAbsolute(destination_path_with_name) catch {};
                try posix.link(source_path_with_name, destination_path_with_name, 0);
            },
            else => {},
        }
    }
}

fn setPermsTree(allocator: std.mem.Allocator, path: []const u8) !void {
    var current_directory = try std.fs.openDirAbsolute(path, .{ .iterate = true });
    defer current_directory.close();

    try std.posix.fchmod(current_directory.fd, 0o755);

    var current_directory_iterator = current_directory.iterate();
    while (try current_directory_iterator.next()) |entry| {
        const entry_path_with_name = try std.fs.path.join(allocator, &.{ path, entry.name });
        defer allocator.free(entry_path_with_name);

        switch (entry.kind) {
            .directory => {
                var child_directory = try std.fs.openDirAbsolute(entry_path_with_name, .{ .iterate = true });
                defer child_directory.close();

                try std.posix.fchmod(child_directory.fd, 0o755);
                try setPermsTree(allocator, entry_path_with_name);
            },
            .file, .sym_link => {
                const file_stat = try std.fs.cwd().statFile(entry_path_with_name);

                var file = try std.fs.openFileAbsolute(entry_path_with_name, .{ .mode = .read_write });
                defer file.close();

                try std.posix.fchmod(file.handle, file_stat.mode & 0o777);
            },
            else => {},
        }
    }
}

fn collectFiles(allocator: std.mem.Allocator, path: []const u8, files_path_list: *std.ArrayList([]const u8)) !void {
    var directory = try std.fs.openDirAbsolute(path, .{ .iterate = true });
    defer directory.close();

    var directory_iterator = directory.iterate();
    while (try directory_iterator.next()) |entry| {
        const entry_path_with_name = try std.fs.path.join(allocator, &.{ path, entry.name });

        switch (entry.kind) {
            .directory => {
                defer allocator.free(entry_path_with_name);
                try collectFiles(allocator, entry_path_with_name, files_path_list);
            },
            .file, .sym_link => try files_path_list.append(entry_path_with_name),
            else => allocator.free(entry_path_with_name),
        }
    }
}
