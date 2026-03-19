const std = @import("std");

const fsm = @import("machine.zig");
const Machine = fsm.Machine;
const StateId = fsm.StateId;

const states = @import("states.zig");

pub const types = @import("types.zig");
pub const PackageMeta = types.PackageMeta;
pub const PrepareRequest = types.PrepareRequest;
pub const BackendError = types.BackendError;

// ── Публичное API ─────────────────────────────────────────────────────────────
pub fn prepare(request: PrepareRequest, allocator: std.mem.Allocator) !PackageMeta {
    var machine = Machine{
        .request = request,
        .stack = std.ArrayList(StateId).init(allocator),
        .allocator = allocator,
        .meta = null,
    };
    defer machine.deinit();

    try states.stateVerifying(&machine);

    return machine.meta orelse BackendError.InvalidPackage;
}
