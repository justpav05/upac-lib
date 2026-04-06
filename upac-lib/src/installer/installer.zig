const std = @import("std");

const database = @import("upac-database");
const PackageMeta = database.PackageMeta;

const file = @import("upac-file");
const c_libs = file.c_libs;

const states = @import("states.zig");

// ── Errors ────────────────────────────────────────────────────────────────────
pub const InstallerError = error{
    AlreadyInstalled,
    PackagePathNotFound,
    RepoPathNotFound,
    RepoOpenFailed,
    MaxRetriesExceeded,
};

// ── StateId ───────────────────────────────────────────────────────────────────
pub const StateId = enum {
    verifying,
    check_installed,
    open_repo,
    process_files,
    write_database,
    process_db_files,
    commit,

    done,
    failed,
};

// ── InstallData ───────────────────────────────────────────────────────────────
pub const InstallData = struct {
    package_meta: PackageMeta,

    package_temp_path: []const u8,
    package_checksum: []const u8,

    repo_path: []const u8,
    index_path: []const u8,
    database_path: []const u8,

    branch: []const u8,

    checkout_path: []const u8,

    max_retries: u8 = 0,
};

// ── InstallerMachine ──────────────────────────────────────────────────────────
pub const InstallerMachine = struct {
    data: InstallData,
    retries: u8,

    repo: ?*c_libs.OstreeRepo,
    mtree: ?*c_libs.OstreeMutableTree,

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
        if (self.mtree) |mtree| c_libs.g_object_unref(mtree);
        if (self.repo) |repo| c_libs.g_object_unref(repo);

        self.stack.deinit();
    }

    pub fn run(install_data: InstallData, allocator: std.mem.Allocator) !void {
        var machine = InstallerMachine{
            .data = install_data,

            .retries = 0,

            .repo = null,
            .mtree = null,

            .stack = std.ArrayList(StateId).init(allocator),
            .allocator = allocator,
        };
        defer machine.deinit();

        try states.stateVerifying(&machine);
    }
};
