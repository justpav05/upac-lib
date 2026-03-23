const std = @import("std");
const posix = std.posix;

const lock = @import("upac-lock");
const Lock = lock.Lock;
const LockKind = lock.LockKind;

const states = @import("states.zig");

// ── Публичные типы ────────────────────────────────────────────────────────────
pub const PackageMeta = struct {
    name: []const u8,
    version: []const u8,
    author: []const u8,
    description: []const u8,
    license: []const u8,
    url: []const u8,
    installed_at: i64,
    checksum: []const u8,
};

pub const PackageFiles = struct {
    name: []const u8,
    paths: []const []const u8,
};

// ── Внутренние типы FSM ───────────────────────────────────────────────────────
pub const DbOperation = enum { add, remove, read_meta, read_files, list };

pub const DbStateId = enum {
    acquiring_lock,
    reading_index,
    reading_package,
    writing_package,
    updating_index,
    updating_package,
    releasing_lock,
    done,
    failed,
};

pub const OperationInput = union(DbOperation) {
    add: struct { meta: PackageMeta, files: PackageFiles },
    remove: struct { name: []const u8 },
    read_meta: struct { name: []const u8 },
    read_files: struct { name: []const u8 },
    list: struct {},
};

pub const OperationResult = union(DbOperation) {
    add: void,
    remove: void,
    read_meta: PackageMeta,
    read_files: PackageFiles,
    list: [][]const u8,
};

pub const DbMachine = struct {
    stack: std.ArrayList(DbStateId),
    lock: ?Lock,
    lock_fd: ?posix.fd_t,
    dir_path: []const u8,
    allocator: std.mem.Allocator,
    input: OperationInput,
    result: ?OperationResult,
    index: ?[][]const u8,

    pub fn enter(self: *DbMachine, id: DbStateId) !void {
        try self.stack.append(id);
    }

    pub fn deinit(self: *DbMachine) void {
        self.stack.deinit();

        if (self.index) |index| {
            for (index) |name| self.allocator.free(name);
            self.allocator.free(index);
        }
    }
};

// ── Запуск машины ─────────────────────────────────────────────────────────────
pub fn runMachine(dir_path: []const u8, allocator: std.mem.Allocator, input: OperationInput) !?OperationResult {
    var database_machine = DbMachine{
        .stack = std.ArrayList(DbStateId).init(allocator),
        .lock = null,
        .lock_fd = null,
        .dir_path = dir_path,
        .allocator = allocator,
        .input = input,
        .result = null,
        .index = null,
    };
    defer database_machine.deinit();

    try states.stateAcquiringLock(&database_machine);
    return database_machine.result;
}

// ── Публичное API ─────────────────────────────────────────────────────────────
/// Добавить или обновить пакет в базе данных.
pub fn addPackage(dir_path: []const u8, package_meta: PackageMeta, package_files: PackageFiles, allocator: std.mem.Allocator) !void {
    _ = try runMachine(dir_path, allocator, .{ .add = .{ .meta = package_meta, .files = package_files } });
}

/// Удалить пакет из базы данных.
pub fn removePackage(dir_path: []const u8, package_name: []const u8, allocator: std.mem.Allocator) !void {
    _ = try runMachine(dir_path, allocator, .{ .remove = .{ .name = package_name } });
}

/// Получить метаданные пакета. Вызывающий освобождает все поля PackageMeta.
pub fn getMeta(dir_path: []const u8, package_name: []const u8, allocator: std.mem.Allocator) !PackageMeta {
    const result = try runMachine(dir_path, allocator, .{ .read_meta = .{ .name = package_name } });
    return result.?.read_meta;
}

/// Получить список файлов пакета. Вызывающий освобождает PackageFiles.paths.
pub fn getFiles(dir_path: []const u8, package_name: []const u8, allocator: std.mem.Allocator) !PackageFiles {
    const result = try runMachine(dir_path, allocator, .{ .read_files = .{ .name = package_name } });
    return result.?.read_files;
}

/// Получить список имён всех установленных пакетов.
/// Вызывающий освобождает каждую строку и слайс.
pub fn listPackages(dir_path: []const u8, allocator: std.mem.Allocator) ![][]const u8 {
    const result = try runMachine(dir_path, allocator, .{ .list = .{} });
    return result.?.list;
}
