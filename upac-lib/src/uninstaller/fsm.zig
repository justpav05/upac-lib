const std = @import("std");

const database = @import("upac-database");

const uninstaller = @import("uninstaller.zig");
const UninstallerMachine = uninstaller.UninstallerMachine;

// ── Состояния ─────────────────────────────────────────────────────────────────
pub fn stateReadingFiles(machine: *UninstallerMachine) anyerror!void {
    try machine.enter(.reading_files);

    const package_files = database.getFiles(
        machine.data.database_path,
        machine.data.package_name,
        machine.allocator,
    ) catch |err| {
        stateFailed(machine);
        return err;
    };

    if (machine.files) |files| {
        for (files) |file_path| machine.allocator.free(file_path);
        machine.allocator.free(files);
    }

    var file_paths = std.ArrayList([]const u8).init(machine.allocator);
    errdefer {
        for (file_paths.items) |file_path| machine.allocator.free(file_path);
        file_paths.deinit();
    }

    for (package_files.paths) |file_path| {
        try file_paths.append(try machine.allocator.dupe(u8, file_path));
    }

    for (package_files.paths) |file_path| machine.allocator.free(file_path);
    machine.allocator.free(package_files.paths);
    machine.allocator.free(package_files.name);

    machine.files = try file_paths.toOwnedSlice();
    machine.resetRetries();

    return stateRemovingLinks(machine);
}

fn stateRemovingLinks(machine: *UninstallerMachine) anyerror!void {
    try machine.enter(.removing_links);

    const file_paths = machine.files orelse {
        stateFailed(machine);
        return error.NoFilesLoaded;
    };

    for (file_paths) |file_path| {
        const package_repo_prefix = try std.fs.path.join(
            machine.allocator,
            &.{ machine.data.repo_path, machine.data.   package_name },
        );
        defer machine.allocator.free(package_repo_prefix);

        const relative_path = if (std.mem.startsWith(u8, file_path, package_repo_prefix))
            file_path[package_repo_prefix.len..]
        else
            file_path;

        const root_file_path = try std.fs.path.join(
            machine.allocator,
            &.{ machine.data.root_path, relative_path },
        );
        defer machine.allocator.free(root_file_path);

        removeEntry(root_file_path) catch |err| switch (err) {
            error.FileNotFound => {
                machine.resetRetries();
                return stateReadingFiles(machine);
            },
            else => {
                if (machine.exhausted()) {
                    stateFailed(machine);
                    return err;
                }
                machine.retries += 1;
                return stateRemovingLinks(machine);
            },
        };
    }

    machine.resetRetries();
    return stateRemovingFiles(machine);
}

fn stateRemovingFiles(machine: *UninstallerMachine) anyerror!void {
    try machine.enter(.removing_files);

    const file_paths = machine.files orelse {
        stateFailed(machine);
        return error.NoFilesLoaded;
    };

    for (file_paths) |file_path| {
        const repo_file_path = try std.fs.path.join(
            machine.allocator,
            &.{ machine.data.repo_path, file_path },
        );
        defer machine.allocator.free(repo_file_path);

        removeEntry(repo_file_path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => {
                if (machine.exhausted()) {
                    stateFailed(machine);
                    return err;
                }
                machine.retries += 1;
                return stateRemovingLinks(machine);
            },
        };
    }

    const package_repo_path = try std.fs.path.join(
        machine.allocator,
        &.{ machine.data.repo_path, machine.data.package_name },
    );
    defer machine.allocator.free(package_repo_path);

    std.fs.deleteTreeAbsolute(package_repo_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };

    machine.resetRetries();
    return stateUnregistering(machine);
}

fn stateUnregistering(machine: *UninstallerMachine) anyerror!void {
    try machine.enter(.unregistering);

    database.removePackage(
        machine.data.database_path,
        machine.data.package_name,
        machine.allocator,
    ) catch |err| {
        if (machine.exhausted()) {
            stateFailed(machine);
            return err;
        }
        machine.retries += 1;
        return stateRemovingLinks(machine);
    };

    machine.resetRetries();
    return stateDone(machine);
}

fn stateDone(machine: *UninstallerMachine) anyerror!void {
    try machine.enter(.done);
}

fn stateFailed(machine: *UninstallerMachine) void {
    _ = machine.enter(.failed) catch {};
    std.debug.print("✗ uninstall failed '{s}', path: ", .{machine.data.package_name});
    for (machine.stack.items) |state| std.debug.print("{s} ", .{@tagName(state)});
    std.debug.print("\n", .{});
}

// ── Вспомогательные функции ───────────────────────────────────────────────────
fn removeEntry(path: []const u8) !void {
    const stat = std.fs.cwd().statFile(path) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };

    switch (stat.kind) {
        .file, .sym_link => try std.fs.deleteFileAbsolute(path),
        .directory => try std.fs.deleteTreeAbsolute(path),
        else => {},
    }
}
