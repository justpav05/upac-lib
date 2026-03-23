const std = @import("std");
const posix = std.posix;

const database = @import("upac-database");

const fsm = @import("fsm.zig");

pub const StateId = enum {
    reading_files,
    removing_links,
    removing_files,
    unregistering,
    done,
    failed,
};

pub const UninstallerMachine = struct {
    data: UninstallData,
    stack: std.ArrayList(StateId),
    retries: u8,
    allocator: std.mem.Allocator,
    files: ?[][]const u8,

    pub fn enter(self: *UninstallerMachine, state_id: StateId) !void {
        try self.stack.append(state_id);
    }

    pub fn resetRetries(self: *UninstallerMachine) void {
        self.retries = 0;
    }

    pub fn exhausted(self: *UninstallerMachine) bool {
        return self.retries >= self.data.max_retries;
    }

    pub fn deinit(self: *UninstallerMachine) void {
        self.stack.deinit();
        if (self.files) |files| {
            for (files) |file_path| self.allocator.free(file_path);
            self.allocator.free(files);
        }
    }
};

pub const UninstallData = struct {
    package_name: []const u8,
    root_path: []const u8,
    repo_path: []const u8,
    database_path: []const u8,
    max_retries: u8 = 0,
};

pub fn uninstall(uninstall_data: UninstallData, allocator: std.mem.Allocator) !void {
    var machine = UninstallerMachine{
        .data = uninstall_data,
        .stack = std.ArrayList(StateId).init(allocator),
        .retries = 0,
        .allocator = allocator,
        .files = null,
    };
    defer machine.deinit();

    try fsm.stateReadingFiles(&machine);
}
