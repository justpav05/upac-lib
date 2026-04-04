const std = @import("std");
const posix = std.posix;

const database = @import("upac-database");
const PackageMeta = database.PackageMeta;
const PackageFiles = database.PackageFiles;

const fms = @import("fsm.zig");

// ── States ────────────────────────────────────────────────────────────────────
pub const StateId = enum {
    verifying,

    copying,
    linking,
    setting_perms,
    registering,

    done,
    failed,
};

// ── Публичные типы ────────────────────────────────────────────────────────────
pub const InstallData = struct {
    package_meta: PackageMeta,
    package_path: []const u8,

    repo_path: []const u8,

    max_retries: u8 = 0,
};

pub const InstallerMachine = struct {
    data: InstallData,

    retries: u8,

    stack: std.ArrayList(StateId),
    allocator: std.mem.Allocator,

    pub fn enter(self: *InstallerMachine, state_id: StateId) !void {
        try self.stack.append(state_id);
    }

    pub fn resetRetries(self: *InstallerMachine) void {
        self.retries = 0;
    }

    pub fn exhausted(self: *InstallerMachine) bool {
        return self.retries >= self.data.max_retries;
    }

    pub fn deinit(self: *InstallerMachine) void {
        self.stack.deinit();
    }

    pub fn run(install_data: InstallData, allocator: std.mem.Allocator) !void {
        var machine = InstallerMachine{
            .data = install_data,
            .stack = std.ArrayList(StateId).init(allocator),
            .retries = 0,
            .allocator = allocator,
        };
        defer machine.deinit();

        try fms.stateVerifying(&machine);
    }
};
