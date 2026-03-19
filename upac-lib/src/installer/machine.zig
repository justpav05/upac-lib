const std = @import("std");
const posix = std.posix;

const InstallRequest = @import("types.zig").InstallRequest;

pub const StateId = enum {
    verifying,
    copying,
    linking,
    setting_perms,
    registering,
    done,
    failed,
};

pub const InstallerMachine = struct {
    state: InstallRequest,
    stack: std.ArrayList(StateId),
    retries: u8,
    allocator: std.mem.Allocator,

    pub fn enter(self: *InstallerMachine, id: StateId) !void {
        try self.stack.append(id);
        std.debug.print("[→ {s}] retries: {}\n", .{ @tagName(id), self.retries });
    }

    pub fn resetRetries(self: *InstallerMachine) void {
        self.retries = 0;
    }

    pub fn exhausted(self: *InstallerMachine) bool {
        return self.retries >= self.state.max_retries;
    }

    pub fn deinit(self: *InstallerMachine) void {
        self.stack.deinit();
    }
};
