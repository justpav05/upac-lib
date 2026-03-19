const std = @import("std");
const posix = std.posix;
const tomlz = @import("tomlz");

const Lock = @import("upac-lock").Lock;
const LockKind = @import("upac-lock").LockKind;

const DbMachine = @import("machine.zig").DbMachine;

const types = @import("types.zig");
const PackageMeta = types.PackageMeta;
const PackageFiles = types.PackageFiles;

// ── Состояния ─────────────────────────────────────────────────────────────────
pub fn stateAcquiringLock(machine: *DbMachine) anyerror!void {
    try machine.enter(.acquiring_lock);

    const lock_path = try std.fs.path.join(machine.allocator, &.{ machine.dir_path, ".lock" });
    defer machine.allocator.free(lock_path);

    const file_descriptor = posix.open(lock_path, .{ .ACCMODE = .RDWR, .CREAT = true }, 0o600) catch |err| {
        stateFailed(machine);
        return err;
    };
    machine.lock_fd = file_descriptor;

    const kind: LockKind = switch (machine.input) {
        .read_meta, .read_files, .list => .shared,
        .add, .remove => .exclusive,
    };

    machine.lock = Lock.tryAcquire(file_descriptor, kind) catch |err| {
        stateFailed(machine);
        return err;
    };

    return stateReadingIndex(machine);
}

fn stateReadingIndex(machine: *DbMachine) anyerror!void {
    try machine.enter(.reading_index);

    const index_path = try std.fs.path.join(machine.allocator, &.{ machine.dir_path, "index.toml" });
    defer machine.allocator.free(index_path);

    const file_content = std.fs.cwd().readFileAlloc(machine.allocator, index_path, 64 * 1024) catch |err| switch (err) {
        error.FileNotFound => {
            machine.index = try machine.allocator.alloc([]const u8, 0);
            return switch (machine.input) {
                .list => {
                    machine.result = .{ .list = machine.index.? };
                    machine.index = null;
                    return stateReleasingLock(machine);
                },
                .read_meta, .read_files => return stateReadingPackage(machine),
                .add, .remove => return stateWritingPackage(machine),
            };
        },
        else => {
            stateFailed(machine);
            return err;
        },
    };
    defer machine.allocator.free(file_content);

    machine.index = parseIndex(machine.allocator, file_content) catch |err| {
        stateFailed(machine);
        return err;
    };

    return switch (machine.input) {
        .list => {
            machine.result = .{ .list = machine.index.? };
            machine.index = null;
            return stateReleasingLock(machine);
        },
        .read_meta, .read_files => return stateReadingPackage(machine),
        .add, .remove => return stateWritingPackage(machine),
    };
}

fn stateReadingPackage(machine: *DbMachine) anyerror!void {
    try machine.enter(.reading_package);

    const name = switch (machine.input) {
        .read_meta => |data| data.name,
        .read_files => |data| data.name,
        else => unreachable,
    };

    const filename = try std.fmt.allocPrint(machine.allocator, "{s}.toml", .{name});
    defer machine.allocator.free(filename);

    const pkg_path = try std.fs.path.join(machine.allocator, &.{ machine.dir_path, filename });
    defer machine.allocator.free(pkg_path);

    const content = std.fs.cwd().readFileAlloc(machine.allocator, pkg_path, 64 * 1024) catch |err| {
        stateFailed(machine);
        return err;
    };
    defer machine.allocator.free(content);

    switch (machine.input) {
        .read_meta => {
            const meta = parseMeta(machine.allocator, content) catch |err| {
                stateFailed(machine);
                return err;
            };
            machine.result = .{ .read_meta = meta };
        },
        .read_files => {
            const files = parseFiles(machine.allocator, name, content) catch |err| {
                stateFailed(machine);
                return err;
            };
            machine.result = .{ .read_files = files };
        },
        else => unreachable,
    }

    return stateReleasingLock(machine);
}

fn stateWritingPackage(machine: *DbMachine) anyerror!void {
    try machine.enter(.writing_package);

    switch (machine.input) {
        .add => |d| {
            const content = serializePackage(machine.allocator, d.meta, d.files) catch |err| {
                stateFailed(machine);
                return err;
            };
            defer machine.allocator.free(content);

            const filename = try std.fmt.allocPrint(machine.allocator, "{s}.toml", .{d.meta.name});
            defer machine.allocator.free(filename);
            const pkg_path = try std.fs.path.join(machine.allocator, &.{ machine.dir_path, filename });
            defer machine.allocator.free(pkg_path);

            writeAtomic(machine.allocator, pkg_path, content) catch |err| {
                stateFailed(machine);
                return err;
            };
        },
        .remove => |d| {
            const filename = try std.fmt.allocPrint(machine.allocator, "{s}.toml", .{d.name});
            defer machine.allocator.free(filename);
            const pkg_path = try std.fs.path.join(machine.allocator, &.{ machine.dir_path, filename });
            defer machine.allocator.free(pkg_path);

            std.fs.deleteFileAbsolute(pkg_path) catch |err| {
                stateFailed(machine);
                return err;
            };
        },
        else => unreachable,
    }

    return stateUpdatingIndex(machine);
}

fn stateUpdatingIndex(machine: *DbMachine) anyerror!void {
    try machine.enter(.updating_index);

    var names = std.ArrayList([]const u8).init(machine.allocator);
    defer names.deinit();

    if (machine.index) |index| for (index) |package| try names.append(package);

    switch (machine.input) {
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

    const content = serializeIndex(machine.allocator, names.items) catch |err| {
        stateFailed(machine);
        return err;
    };
    defer machine.allocator.free(content);

    const index_path = try std.fs.path.join(machine.allocator, &.{ machine.dir_path, "index.toml" });
    defer machine.allocator.free(index_path);

    writeAtomic(machine.allocator, index_path, content) catch |err| {
        stateFailed(machine);
        return err;
    };

    return stateReleasingLock(machine);
}

fn stateReleasingLock(machine: *DbMachine) anyerror!void {
    try machine.enter(.releasing_lock);
    if (machine.lock) |*lock| {
        lock.release();
        machine.lock = null;
    }
    if (machine.lock_fd) |fd| {
        posix.close(fd);
        machine.lock_fd = null;
    }
    return stateDone(machine);
}

fn stateDone(machine: *DbMachine) anyerror!void {
    try machine.enter(.done);
}

fn stateFailed(machine: *DbMachine) void {
    _ = machine.enter(.failed) catch {};
    if (machine.lock) |*lock| {
        lock.release();
        machine.lock = null;
    }
    if (machine.lock_fd) |file_descriptor| {
        posix.close(file_descriptor);
        machine.lock_fd = null;
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
    var table = try tomlz.parse(allocator, content);
    defer table.deinit(allocator);

    const arr = table.getArray("packages") orelse
        return allocator.alloc([]const u8, 0);

    var names = std.ArrayList([]const u8).init(allocator);
    errdefer {
        for (names.items) |n| allocator.free(n);
        names.deinit();
    }

    for (0..arr.items().len) |index| {
        const string = arr.getString(index) orelse return error.InvalidIndexEntry;
        try names.append(try allocator.dupe(u8, string));
    }

    return names.toOwnedSlice();
}

fn serializeIndex(allocator: std.mem.Allocator, names: []const []const u8) ![]u8 {
    var buf = std.ArrayList(u8).init(allocator);
    errdefer buf.deinit();
    const w = buf.writer();

    try w.writeAll("packages = [");
    for (names, 0..) |name, i| {
        if (i > 0) try w.writeAll(", ");
        try w.print("\"{s}\"", .{name});
    }
    try w.writeAll("]\n");

    return buf.toOwnedSlice();
}

fn parseMeta(allocator: std.mem.Allocator, content: []const u8) !PackageMeta {
    var table = try tomlz.parse(allocator, content);
    defer table.deinit(allocator);

    const package_metadata = table.getTable("meta") orelse return error.MissingMetaSection;

    return PackageMeta{
        .name = try allocator.dupe(u8, package_metadata.getString("name") orelse return error.MissingField),
        .version = try allocator.dupe(u8, package_metadata.getString("version") orelse return error.MissingField),
        .author = try allocator.dupe(u8, package_metadata.getString("author") orelse return error.MissingField),
        .description = try allocator.dupe(u8, package_metadata.getString("description") orelse ""),
        .license = try allocator.dupe(u8, package_metadata.getString("license") orelse ""),
        .url = try allocator.dupe(u8, package_metadata.getString("url") orelse ""),
        .installed_at = package_metadata.getInteger("installed_at") orelse 0,
        .checksum = try allocator.dupe(u8, package_metadata.getString("checksum") orelse ""),
    };
}

fn parseFiles(allocator: std.mem.Allocator, name: []const u8, content: []const u8) !PackageFiles {
    var table = try tomlz.parse(allocator, content);
    defer table.deinit(allocator);

    const section = table.getTable("files") orelse return error.MissingFilesSection;
    const arr = section.getArray("paths") orelse return error.MissingPathsField;

    var paths = std.ArrayList([]const u8).init(allocator);
    errdefer {
        for (paths.items) |p| allocator.free(p);
        paths.deinit();
    }

    for (0..arr.items().len) |index| {
        const string = arr.getString(index) orelse return error.InvalidFilePath;
        try paths.append(try allocator.dupe(u8, string));
    }

    return PackageFiles{
        .name = try allocator.dupe(u8, name),
        .paths = try paths.toOwnedSlice(),
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
