const std = @import("std");

const types = @import("types.zig");
const PackageMeta = types.PackageMeta;
const PrepareRequest = types.PrepareRequest;

// ── Внутренние типы FSM ───────────────────────────────────────────────────────

pub const StateId = enum {
    verifying,
    extracting,
    reading_meta,
    done,
    failed,
};

pub const Machine = struct {
    request: PrepareRequest,
    stack: std.ArrayList(StateId),
    allocator: std.mem.Allocator,
    // Результат — заполняется в reading_meta
    meta: ?PackageMeta,

    pub fn enter(self: *Machine, id: StateId) !void {
        try self.stack.append(id);
        std.debug.print("[arch → {s}]\n", .{@tagName(id)});
    }

    pub fn deinit(self: *Machine) void {
        self.stack.deinit();
    }
};
