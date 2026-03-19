const std = @import("std");
const posix = std.posix;
const tomlz = @import("tomlz");
const states = @import("states.zig");

const Lock = @import("upac-lock").Lock;
const LockKind = @import("upac-lock").LockKind;

const types = @import("types.zig");
const PackageMeta = types.PackageMeta;
const PackageFiles = types.PackageFiles;

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
pub fn runMachine(
    dir_path: []const u8,
    allocator: std.mem.Allocator,
    input: OperationInput,
) !?OperationResult {
    var machine = DbMachine{
        .stack = std.ArrayList(DbStateId).init(allocator),
        .lock = null,
        .lock_fd = null,
        .dir_path = dir_path,
        .allocator = allocator,
        .input = input,
        .result = null,
        .index = null,
    };
    defer machine.deinit();

    try states.stateAcquiringLock(&machine);
    return machine.result;
}
