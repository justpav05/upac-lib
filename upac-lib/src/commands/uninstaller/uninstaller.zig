// ── Imports ─────────────────────────────────────────────────────────────────────
const std = @import("std");

const data = @import("upac-data");

const CSlice = ffi.CSlice;
const UninstallProgressFn = ffi.UninstallProgressFn;
const UninstallProgressEvent = ffi.UninstallProgressEvent;

const file = @import("upac-file");
const c_libs = file.c_libs;

const states = @import("states.zig");

// ── Public imports ─────────────────────────────────────────────────────────────────────
pub const ffi = @import("upac-ffi");

// ── Imports symbols ─────────────────────────────────────────────────────────────────────
pub usingnamespace @import("symbols.zig");

// ── Errors ─────────────────────────────────────────────────────────────────────
// Errors specific to the removal process
pub const UninstallerError = error{
    PackageNotFound,
    RepoPathNotFound,
    RepoOpenFailed,
    FileNotFound,
    FileMapCorrupted,
    MaxRetriesExceeded,
};

// ── UninstallerFSM states ─────────────────────────────────────────────────────────────────────
// Stages of the removal process
pub const StateId = enum {
    verifying,
    open_repo,
    check_installed,
    load_files,
    remove_files,
    remove_db_files,
    commit,
    checkout_staging,
    atomic_swap,
    cleanup_staging,

    done,
    failed,
};

// ── UninstallerFSM data ─────────────────────────────────────────────────────────────────────
// Set of input parameters: package name, paths to the repository and database, as well as the target branch for the commit
pub const UninstallData = struct {
    package_names: []const []const u8,

    repo_path: []const u8,
    root_path: []const u8,
    db_path: []const u8,

    branch: []const u8,

    on_progress: ?UninstallProgressFn = null,
    progress_ctx: ?*anyopaque = null,

    max_retries: u8 = 0,
};

// ── UninstallerFSM ─────────────────────────────────────────────────────────────────────
// Uninstaller state container for fsm data between states
pub const UninstallerMachine = struct {
    data: UninstallData,
    retries: u8,

    repo: ?*c_libs.OstreeRepo,
    mtree: ?*c_libs.OstreeMutableTree,

    staging_path: ?[:0]const u8 = null,
    commit_checksum: ?[*:0]u8 = null,

    current_package_index: usize,

    package_file_map: ?data.FileMap,
    package_checksum: ?[]const u8,

    stack: std.ArrayList(StateId),
    allocator: std.mem.Allocator,

    // Registers a transition to a new state, adding it to the stack for progress tracking and debugging
    pub fn enter(self: *UninstallerMachine, state_id: StateId) !void {
        try self.stack.append(state_id);
        self.report(switch (state_id) {
            .verifying => .verifying,
            .open_repo => .open_repo,
            .check_installed => .check_installed,
            .remove_db_files => .remove_db_files,
            .commit => .commit,
            .done => .done,
            .failed => .failed,
            else => return,
        });
    }

    // Resets the retry counter before executing a new operation
    pub fn resetRetries(self: *UninstallerMachine) void {
        self.retries = 0;
    }

    // Checks whether the attempt limit for the current uninstallation step has been exhausted
    pub fn exhausted(self: *UninstallerMachine) bool {
        return self.retries >= self.data.max_retries;
    }

    // Releases all resources: native Zig memory, the file hash map, and OSTree system C objects
    pub fn deinit(self: *UninstallerMachine) void {
        if (self.staging_path) |path| self.allocator.free(path);
        if (self.commit_checksum) |checksum| c_libs.g_free(@ptrCast(checksum));

        if (self.package_file_map) |*map| data.freeFileMap(@constCast(map), self.allocator);
        if (self.package_checksum) |checksum| self.allocator.free(checksum);

        if (self.mtree) |mtree| c_libs.g_object_unref(mtree);
        if (self.repo) |repo| c_libs.g_object_unref(repo);

        self.stack.deinit();
    }

    // Resets the transaction by aborting any ongoing transaction and preparing a new one. If the transaction cannot be reset, returns an error
    pub fn resetTransaction(self: *UninstallerMachine) !void {
        var gerror: ?*c_libs.GError = null;
        _ = c_libs.ostree_repo_abort_transaction(self.repo.?, null, null);
        if (c_libs.ostree_repo_prepare_transaction(self.repo.?, null, null, &gerror) == 0) {
            if (gerror) |err| c_libs.g_error_free(err);
            return UninstallerError.RepoOpenFailed;
        }
    }

    // Reports an uninstallation progress event to the progress callback, if one is set
    pub fn report(self: *UninstallerMachine, event: UninstallProgressEvent) void {
        const cb = self.data.on_progress orelse return;
        const name = if (self.current_package_index < self.data.package_names.len)
            self.data.package_names[self.current_package_index]
        else
            "";
        cb(event, CSlice.fromSlice(name), self.data.progress_ctx);
    }

    // Entry point: initializes the uninstallation engine and launches the package removal process
    pub fn run(uninstall_data: UninstallData, allocator: std.mem.Allocator) !void {
        var machine = UninstallerMachine{
            .data = uninstall_data,
            .retries = 0,

            .repo = null,
            .mtree = null,

            .current_package_index = 0,

            .package_file_map = null,
            .package_checksum = null,

            .stack = std.ArrayList(StateId).init(allocator),
            .allocator = allocator,
        };
        defer machine.deinit();

        try states.stateVerifying(&machine);
    }
};
