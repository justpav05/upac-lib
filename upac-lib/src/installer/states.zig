const std = @import("std");
const posix = std.posix;

const database = @import("upac-database");
const PackageFiles = database.PackageFiles;

const InstallerMachine = @import("machine.zig").InstallerMachine;
const StateId = @import("machine.zig").StateId;

// ── Состояния ─────────────────────────────────────────────────────────────────
pub fn stateVerifying(machine: *InstallerMachine) anyerror!void {
    try machine.enter(.verifying);

    std.fs.accessAbsolute(machine.state.package_path, .{}) catch |err| {
        stateFailed(machine);
        return err;
    };

    std.fs.accessAbsolute(machine.state.repo_path, .{}) catch |err| {
        stateFailed(machine);
        return err;
    };

    machine.resetRetries();
    return stateCopying(machine);
}

pub fn stateCopying(machine: *InstallerMachine) anyerror!void {
    try machine.enter(.copying);

    var package_dir = std.fs.openDirAbsolute(machine.state.package_path, .{ .iterate = true }) catch |err| {
        if (machine.exhausted()) {
            stateFailed(machine);
            return err;
        }
        machine.retries += 1;
        return stateCopying(machine);
    };
    defer package_dir.close();

    copyDir(machine.allocator, package_dir, machine.state.package_path, machine.state.repo_path) catch |err| {
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

    var repo_dir = std.fs.openDirAbsolute(machine.state.repo_path, .{ .iterate = true }) catch |err| {
        if (machine.exhausted()) {
            stateFailed(machine);
            return err;
        }
        machine.retries += 1;
        return stateCopying(machine);
    };
    defer repo_dir.close();

    linkDir(machine.allocator, machine.state.repo_path, machine.state.root_path) catch |err| switch (err) {
        error.FileNotFound => {
            machine.resetRetries();
            return stateCopying(machine);
        },
        else => {
            if (machine.exhausted()) {
                stateFailed(machine);
                return err;
            }
            machine.retries += 1;
            return stateLinking(machine);
        },
    };

    machine.resetRetries();
    return stateSettingPerms(machine);
}

pub fn stateSettingPerms(machine: *InstallerMachine) anyerror!void {
    try machine.enter(.setting_perms);

    var root_dir = std.fs.openDirAbsolute(machine.state.root_path, .{ .iterate = true }) catch |err| {
        if (machine.exhausted()) {
            stateFailed(machine);
            return err;
        }
        machine.retries += 1;
        return stateLinking(machine);
    };
    defer root_dir.close();

    setPermsDir(machine.allocator, machine.state.root_path) catch |err| switch (err) {
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

    collectFiles(machine.allocator, machine.state.root_path, &files_list) catch |err| {
        if (machine.exhausted()) {
            stateFailed(machine);
            return err;
        }
        machine.retries += 1;
        return stateRegistering(machine);
    };

    const pkg_files = PackageFiles{
        .name = machine.state.meta.name,
        .paths = files_list.items,
    };

    database.addPackage(machine.state.db_path, machine.state.meta, pkg_files, machine.allocator) catch |err| {
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

pub fn stateDone(m: *InstallerMachine) anyerror!void {
    try m.enter(.done);
    std.debug.print("✓ installed '{s}' {s}\n", .{
        m.state.meta.name,
        m.state.meta.version,
    });
}

pub fn stateFailed(m: *InstallerMachine) void {
    _ = m.enter(.failed) catch {};
    std.debug.print("✗ install failed '{s}', path: ", .{m.state.meta.name});
    for (m.stack.items) |s| std.debug.print("{s} ", .{@tagName(s)});
    std.debug.print("\n", .{});
}

// ── Вспомогательные функции ───────────────────────────────────────────────────
fn copyDir(
    allocator: std.mem.Allocator,
    src_dir: std.fs.Dir,
    src_path: []const u8,
    dst_path: []const u8,
) !void {
    var iter = src_dir.iterate();
    while (try iter.next()) |entry| {
        const src_entry = try std.fs.path.join(allocator, &.{ src_path, entry.name });
        defer allocator.free(src_entry);
        const dst_entry = try std.fs.path.join(allocator, &.{ dst_path, entry.name });
        defer allocator.free(dst_entry);

        switch (entry.kind) {
            .directory => {
                std.fs.makeDirAbsolute(dst_entry) catch |err| switch (err) {
                    error.PathAlreadyExists => {},
                    else => return err,
                };
                var sub_dir = try std.fs.openDirAbsolute(src_entry, .{ .iterate = true });
                defer sub_dir.close();
                try copyDir(allocator, sub_dir, src_entry, dst_entry);
            },
            .file => {
                try std.fs.copyFileAbsolute(src_entry, dst_entry, .{});
            },
            else => {},
        }
    }
}

fn linkDir(
    allocator: std.mem.Allocator,
    src_path: []const u8,
    dst_path: []const u8,
) !void {
    var src_dir = try std.fs.openDirAbsolute(src_path, .{ .iterate = true });
    defer src_dir.close();

    var iter = src_dir.iterate();
    while (try iter.next()) |entry| {
        const src_entry = try std.fs.path.join(allocator, &.{ src_path, entry.name });
        defer allocator.free(src_entry);
        const dst_entry = try std.fs.path.join(allocator, &.{ dst_path, entry.name });
        defer allocator.free(dst_entry);

        switch (entry.kind) {
            .directory => {
                std.fs.makeDirAbsolute(dst_entry) catch |err| switch (err) {
                    error.PathAlreadyExists => {},
                    else => return err,
                };
                try linkDir(allocator, src_entry, dst_entry);
            },
            .file => {
                std.fs.deleteFileAbsolute(dst_entry) catch {};
                try posix.link(src_entry, dst_entry, 0);
            },
            else => {},
        }
    }
}

fn setPermsDir(allocator: std.mem.Allocator, path: []const u8) !void {
    var dir = try std.fs.openDirAbsolute(path, .{ .iterate = true });
    defer dir.close();

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        const entry_path = try std.fs.path.join(allocator, &.{ path, entry.name });
        defer allocator.free(entry_path);

        switch (entry.kind) {
            .directory => {
                var sub_dir = try std.fs.openDirAbsolute(entry_path, .{});
                defer sub_dir.close();
                try sub_dir.chmod(0o755);
                try setPermsDir(allocator, entry_path);
            },
            .file, .sym_link => {
                var file = try std.fs.openFileAbsolute(entry_path, .{ .mode = .read_write });
                defer file.close();
                try file.chmod(0o644);
            },
            else => {},
        }
    }
}

fn collectFiles(
    allocator: std.mem.Allocator,
    path: []const u8,
    out: *std.ArrayList([]const u8),
) !void {
    var dir = try std.fs.openDirAbsolute(path, .{ .iterate = true });
    defer dir.close();

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        const entry_path = try std.fs.path.join(allocator, &.{ path, entry.name });
        switch (entry.kind) {
            .directory => try collectFiles(allocator, entry_path, out),
            .file, .sym_link => try out.append(entry_path),
            else => allocator.free(entry_path),
        }
    }
}
