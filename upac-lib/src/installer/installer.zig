const std = @import("std");
const posix = std.posix;

const InstallerMachine = @import("machine.zig").InstallerMachine;
const StateId = @import("machine.zig").StateId;

pub const types = @import("types.zig");
pub const InstallRequest = types.InstallRequest;

const states = @import("states.zig");
const fsm = @import("machine.zig");

pub fn install(request: InstallRequest, allocator: std.mem.Allocator) !void {
    var machine = InstallerMachine{
        .state = request,
        .stack = std.ArrayList(StateId).init(allocator),
        .retries = 0,
        .allocator = allocator,
    };
    defer machine.deinit();

    try states.stateVerifying(&machine);
}
