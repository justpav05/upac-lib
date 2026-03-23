const std = @import("std");
const posix = std.posix;
const toml = @import("upac-toml");

const Lock = @import("upac-lock").Lock;
const LockKind = @import("upac-lock").LockKind;

const database = @import("database.zig");
const DbMachine = database.DbMachine;
const PackageMeta = database.PackageMeta;
const PackageFiles = database.PackageFiles;

// ── Состояния ─────────────────────────────────────────────────────────────────
pub fn stateAcquiringLock(database_machine: *DbMachine) anyerror!void {
    try database_machine.enter(.acquiring_lock);

    const lock_path = try std.fs.path.join(database_machine.allocator, &.{ database_machine.dir_path, ".lock" });
    defer database_machine.allocator.free(lock_path);

    const file_descriptor = posix.open(lock_path, .{ .ACCMODE = .RDWR, .CREAT = true }, 0o600) catch |err| {
        stateFailed(database_machine);
        return err;
    };
    database_machine.lock_fd = file_descriptor;

    const kind: LockKind = switch (database_machine.input) {
        .read_meta, .read_files, .list => .shared,
        .add, .remove => .exclusive,
    };

    database_machine.lock = Lock.tryAcquire(file_descriptor, kind) catch |err| {
        stateFailed(database_machine);
        return err;
    };

    return stateReadingIndex(database_machine);
}

fn stateReadingIndex(database_machine: *DbMachine) anyerror!void {
    try database_machine.enter(.reading_index);

    const index_path = try std.fs.path.join(database_machine.allocator, &.{ database_machine.dir_path, "index.toml" });
    defer database_machine.allocator.free(index_path);

    const file_content = std.fs.cwd().readFileAlloc(database_machine.allocator, index_path, 64 * 1024) catch |err| switch (err) {
        error.FileNotFound => {
            database_machine.index = try database_machine.allocator.alloc([]const u8, 0);
            return switch (database_machine.input) {
                .list => {
                    database_machine.result = .{ .list = database_machine.index.? };
                    database_machine.index = null;
                    return stateReleasingLock(database_machine);
                },
                .read_meta, .read_files => return stateReadingPackage(database_machine),
                .add, .remove => return stateWritingPackage(database_machine),
            };
        },
        else => {
            stateFailed(database_machine);
            return err;
        },
    };
    defer database_machine.allocator.free(file_content);

    database_machine.index = parseIndex(database_machine.allocator, file_content) catch |err| {
        stateFailed(database_machine);
        return err;
    };

    return switch (database_machine.input) {
        .list => {
            database_machine.result = .{ .list = database_machine.index.? };
            database_machine.index = null;
            return stateReleasingLock(database_machine);
        },
        .read_meta, .read_files => return stateReadingPackage(database_machine),
        .add, .remove => return stateWritingPackage(database_machine),
    };
}

fn stateReadingPackage(database_machine: *DbMachine) anyerror!void {
    try database_machine.enter(.reading_package);

    const name = switch (database_machine.input) {
        .read_meta => |data| data.name,
        .read_files => |data| data.name,
        else => unreachable,
    };

    const filename = try std.fmt.allocPrint(database_machine.allocator, "{s}.toml", .{name});
    defer database_machine.allocator.free(filename);

    const pkg_path = try std.fs.path.join(database_machine.allocator, &.{ database_machine.dir_path, filename });
    defer database_machine.allocator.free(pkg_path);

    const content = std.fs.cwd().readFileAlloc(database_machine.allocator, pkg_path, 64 * 1024) catch |err| {
        stateFailed(database_machine);
        return err;
    };
    defer database_machine.allocator.free(content);

    switch (database_machine.input) {
        .read_meta => {
            const meta = parseMeta(database_machine.allocator, content) catch |err| {
                stateFailed(database_machine);
                return err;
            };
            database_machine.result = .{ .read_meta = meta };
        },
        .read_files => {
            const files = parseFiles(database_machine.allocator, name, content) catch |err| {
                stateFailed(database_machine);
                return err;
            };
            database_machine.result = .{ .read_files = files };
        },
        else => unreachable,
    }

    return stateReleasingLock(database_machine);
}

fn stateWritingPackage(database_machine: *DbMachine) anyerror!void {
    try database_machine.enter(.writing_package);

    switch (database_machine.input) {
        .add => |d| {
            const content = serializePackage(database_machine.allocator, d.meta, d.files) catch |err| {
                stateFailed(database_machine);
                return err;
            };
            defer database_machine.allocator.free(content);

            const filename = try std.fmt.allocPrint(database_machine.allocator, "{s}.toml", .{d.meta.name});
            defer database_machine.allocator.free(filename);
            const pkg_path = try std.fs.path.join(database_machine.allocator, &.{ database_machine.dir_path, filename });
            defer database_machine.allocator.free(pkg_path);

            writeAtomic(database_machine.allocator, pkg_path, content) catch |err| {
                stateFailed(database_machine);
                return err;
            };
        },
        .remove => |d| {
            const filename = try std.fmt.allocPrint(database_machine.allocator, "{s}.toml", .{d.name});
            defer database_machine.allocator.free(filename);
            const pkg_path = try std.fs.path.join(database_machine.allocator, &.{ database_machine.dir_path, filename });
            defer database_machine.allocator.free(pkg_path);

            std.fs.deleteFileAbsolute(pkg_path) catch |err| {
                stateFailed(database_machine);
                return err;
            };
        },
        else => unreachable,
    }

    return stateUpdatingIndex(database_machine);
}

fn stateUpdatingIndex(database_machine: *DbMachine) anyerror!void {
    try database_machine.enter(.updating_index);

    var names = std.ArrayList([]const u8).init(database_machine.allocator);
    defer names.deinit();

    if (database_machine.index) |index| for (index) |package| try names.append(package);

    switch (database_machine.input) {
        .add => |data| {
            const exists = for (names.items) |package| {
                if (std.mem.eql(u8, package, data.meta.name)) break true;
            } else false;
            if (!exists) try names.append(data.meta.name);
        },
        .remove => |data| {
            var index: usize = 0;
            while (index < names.items.len) {
                if (std.mem.eql(u8, names.items[index], data.name)) {
                    _ = names.swapRemove(index);
                } else {
                    index += 1;
                }
            }
        },
        else => unreachable,
    }

    const content = serializeIndex(database_machine.allocator, names.items) catch |err| {
        stateFailed(database_machine);
        return err;
    };
    defer database_machine.allocator.free(content);

    const index_path = try std.fs.path.join(database_machine.allocator, &.{ database_machine.dir_path, "index.toml" });
    defer database_machine.allocator.free(index_path);

    writeAtomic(database_machine.allocator, index_path, content) catch |err| {
        stateFailed(database_machine);
        return err;
    };

    return stateReleasingLock(database_machine);
}

fn stateReleasingLock(database_machine: *DbMachine) anyerror!void {
    try database_machine.enter(.releasing_lock);
    if (database_machine.lock) |*lock| {
        lock.release();
        database_machine.lock = null;
    }
    if (database_machine.lock_fd) |fd| {
        posix.close(fd);
        database_machine.lock_fd = null;
    }
    return stateDone(database_machine);
}

fn stateDone(database_machine: *DbMachine) anyerror!void {
    try database_machine.enter(.done);
}

fn stateFailed(database_machine: *DbMachine) void {
    _ = database_machine.enter(.failed) catch {};
    if (database_machine.lock) |*lock| {
        lock.release();
        database_machine.lock = null;
    }
    if (database_machine.lock_fd) |file_descriptor| {
        posix.close(file_descriptor);
        database_machine.lock_fd = null;
    }
}

// ── Вспомогательные функции ───────────────────────────────────────────────────
fn writeAtomic(allocator: std.mem.Allocator, path: []const u8, content: []const u8) !void {
    const tmp_path = try std.fmt.allocPrint(allocator, "{s}.tmp", .{path});
    defer allocator.free(tmp_path);

    try std.fs.cwd().writeFile(.{ .sub_path = tmp_path, .data = content });
    try posix.rename(tmp_path, path);
}

fn parseIndex(allocator: std.mem.Allocator, content: []const u8) ![][]const u8 {
    var document = try toml.parse(allocator, content);
    defer document.deinit();

    const packages_array = document.getArray("", "packages") orelse return allocator.alloc([]const u8, 0);

    var package_names = std.ArrayList([]const u8).init(allocator);
    errdefer {
        for (package_names.items) |package_name| allocator.free(package_name);
        package_names.deinit();
    }

    for (packages_array) |package_name| {
        try package_names.append(try allocator.dupe(u8, package_name));
    }

    return package_names.toOwnedSlice();
}

fn serializeIndex(allocator: std.mem.Allocator, names: []const []const u8) ![]u8 {
    var buf = std.ArrayList(u8).init(allocator);
    errdefer buf.deinit();
    const writer = buf.writer();

    try writer.writeAll("packages = [");
    for (names, 0..) |name, i| {
        if (i > 0) try writer.writeAll(", ");
        try writer.print("\"{s}\"", .{name});
    }
    try writer.writeAll("]\n");

    return buf.toOwnedSlice();
}

fn parseMeta(allocator: std.mem.Allocator, content: []const u8) !PackageMeta {
    var document = try toml.parse(allocator, content);
    defer document.deinit();

    return PackageMeta{
        .name = try allocator.dupe(u8, document.getString("meta", "name") orelse return error.MissingField),
        .version = try allocator.dupe(u8, document.getString("meta", "version") orelse return error.MissingField),
        .author = try allocator.dupe(u8, document.getString("meta", "author") orelse return error.MissingField),
        .description = try allocator.dupe(u8, document.getString("meta", "description") orelse ""),
        .license = try allocator.dupe(u8, document.getString("meta", "license") orelse ""),
        .url = try allocator.dupe(u8, document.getString("meta", "url") orelse ""),
        .installed_at = document.getInteger("meta", "installed_at") orelse 0,
        .checksum = try allocator.dupe(u8, document.getString("meta", "checksum") orelse ""),
    };
}

fn parseFiles(allocator: std.mem.Allocator, package_name: []const u8, content: []const u8) !PackageFiles {
    var document = try toml.parse(allocator, content);
    defer document.deinit();

    const file_paths_array = document.getArray("files", "paths") orelse return error.MissingPathsField;

    var file_paths = std.ArrayList([]const u8).init(allocator);
    errdefer {
        for (file_paths.items) |file_path| allocator.free(file_path);
        file_paths.deinit();
    }

    for (file_paths_array) |file_path| {
        try file_paths.append(try allocator.dupe(u8, file_path));
    }

    return PackageFiles{
        .name = try allocator.dupe(u8, package_name),
        .paths = try file_paths.toOwnedSlice(),
    };
}

fn serializePackage(allocator: std.mem.Allocator, meta: PackageMeta, files: PackageFiles) ![]u8 {
    var buf = std.ArrayList(u8).init(allocator);
    errdefer buf.deinit();
    const buf_writer = buf.writer();

    try buf_writer.print(
        \\[meta]
        \\name         = "{s}"
        \\version      = "{s}"
        \\author       = "{s}"
        \\description  = "{s}"
        \\license      = "{s}"
        \\url          = "{s}"
        \\installed_at = {d}
        \\checksum     = "{s}"
        \\
        \\[files]
        \\paths = [
        \\
    , .{
        meta.name,         meta.version,  meta.author,
        meta.description,  meta.license,  meta.url,
        meta.installed_at, meta.checksum,
    });

    for (files.paths) |path| {
        try buf_writer.print("    \"{s}\",\n", .{path});
    }
    try buf_writer.writeAll("]\n");

    return buf.toOwnedSlice();
}
