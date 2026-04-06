const std = @import("std");

const data_mod = @import("upac-data");

const file_mod = @import("upac-file");
const c_libs = file_mod.c_libs;

const states = @import("states.zig");

pub const UninstallerError = error{
    PackageNotFound,
    RepoPathNotFound,
    RepoOpenFailed,
    MaxRetriesExceeded,
};

pub const StateId = enum {
    verifying,
    open_repo,
    check_installed,
    load_files,
    remove_files,
    remove_db_files,
    commit,
    done,
    failed,
};

pub const UninstallData = struct {
    package_name: []const u8,

    repo_path: []const u8,
    db_path: []const u8,
    branch: []const u8,
    checkout_path: []const u8,

    max_retries: u8 = 0,
};

pub const UninstallerMachine = struct {
    data: UninstallData,
    retries: u8,

    repo: ?*c_libs.OstreeRepo,
    mtree: ?*c_libs.OstreeMutableTree,
    package_checksum: ?[]const u8,
    package_file_map: ?data_mod.FileMap,

    stack: std.ArrayList(StateId),
    allocator: std.mem.Allocator,

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
        if (self.package_checksum) |checksum| self.allocator.free(checksum);
        if (self.package_file_map) |*file_map| data_mod.freeFileMap(file_map, self.allocator);
        if (self.mtree) |mtree| c_libs.g_object_unref(mtree);
        if (self.repo) |repo| c_libs.g_object_unref(repo);
        self.stack.deinit();
    }

    pub fn run(uninstall_data: UninstallData, allocator: std.mem.Allocator) !void {
        var machine = UninstallerMachine{
            .data = uninstall_data,
            .retries = 0,
            .repo = null,
            .mtree = null,
            .package_checksum = null,
            .package_file_map = null,
            .stack = std.ArrayList(StateId).init(allocator),
            .allocator = allocator,
        };
        defer machine.deinit();

        try states.stateVerifying(&machine);
    }
};
