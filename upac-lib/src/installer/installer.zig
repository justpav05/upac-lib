// ── Imports ─────────────────────────────────────────────────────────────────────
const std = @import("std");

const types = @import("upac-types");
const Package = types.Package;
const PackageMeta = types.PackageMeta;

const file = @import("upac-file");
const c_libs = file.c_libs;

const states = @import("states.zig");

// ── Errors ────────────────────────────────────────────────────────────────────
//
pub const InstallerError = error{
    AlreadyInstalled,
    PackagePathNotFound,
    RepoPathNotFound,
    RepoOpenFailed,
    MaxRetriesExceeded,
};

// ── StateId ───────────────────────────────────────────────────────────────────
// Listing of all stages of the installation's lifecycle
pub const StateId = enum {
    verifying,
    check_installed,
    open_repo,
    write_database,
    process_db_files,
    commit,

    done,
    failed,
};

pub const InstallEntry = struct {
    package: Package,
    temp_path: []const u8,
    checksum: []const u8,
};

// ── InstallData ───────────────────────────────────────────────────────────────
// A container structure holding all installation parameters: package metadata, paths to the repository and database, as well as retry limits
pub const InstallData = struct {
    packages: []const InstallEntry,

    repo_path: []const u8,
    root_path: []const u8,
    database_path: []const u8,

    branch: []const u8,

    max_retries: u8 = 0,
};

// ── InstallerMachine ──────────────────────────────────────────────────────────
// The main structure of a finite-state machine, with information persistence between states
pub const InstallerMachine = struct {
    data: InstallData,
    retries: u8,

    repo: ?*c_libs.OstreeRepo,
    mtree: ?*c_libs.OstreeMutableTree,

    current_package_index: usize = 0,

    stack: std.ArrayList(StateId),
    allocator: std.mem.Allocator,

    // Registers a transition to a new state, saving it to the stack. This allows for the reconstruction of the sequence of actions during debugging
    pub fn enter(self: *InstallerMachine, state_id: StateId) !void {
        try self.stack.append(state_id);
    }

    // Resets the attempt counter before starting a new operation
    pub fn resetRetries(self: *InstallerMachine) void {
        self.retries = 0;
    }

    // Checks whether the retry limit for the current step has been exceeded. If the limit is exhausted, the installation is interrupted
    pub fn exhausted(self: *InstallerMachine) bool {
        return self.retries >= self.data.max_retries;
    }

    // Correct memory deallocation function
    pub fn deinit(self: *InstallerMachine) void {
        if (self.mtree) |mtree| c_libs.g_object_unref(mtree);
        if (self.repo) |repo| c_libs.g_object_unref(repo);

        self.stack.deinit();
    }

    // Initializes the machine, creates the state stack, and launches the first stage—verification
    pub fn run(install_data: InstallData, allocator: std.mem.Allocator) !void {
        var machine = InstallerMachine{
            .data = install_data,

            .retries = 0,

            .repo = null,
            .mtree = null,

            .current_package_index = 0,

            .stack = std.ArrayList(StateId).init(allocator),
            .allocator = allocator,
        };
        defer machine.deinit();

        try states.stateVerifying(&machine);
    }
};
