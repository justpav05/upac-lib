// ── Imports ─────────────────────────────────────────────────────────────────────
const data = @import("upac-data");

const UninstallStateId = ffi.UninstallStateId;
const UninstallProgressFn = ffi.UninstallProgressFn;

const states = @import("states.zig");

// ── Public imports ─────────────────────────────────────────────────────────────────────
pub const std = @import("std");
pub const ffi = @import("upac-ffi");
pub const c_libs = ffi.c_libs;

pub const CSlice = ffi.CSlice;

const isCancelRequested = ffi.isCancelRequested;

pub const stateFailed = states.stateFailed;

// ── Errors ─────────────────────────────────────────────────────────────────────
// Errors specific to the removal process
pub const UninstallerError = error{
    // Specific errors
    PackageNotFound,
    FileNotFound,
    FileMapCorrupted,
    StagingNotCleaned,
    // Global errors
    PathNotFound,
    RepoOpenFailed,
    RepoTransactionFailed,
    CheckoutFailed,
    AllocZFailed,
    OutOfMemory,
    Cancelled,
    MaxRetriesExceeded,
};

// ── UninstallerFSM data ─────────────────────────────────────────────────────────────────────
// Set of input parameters: package name, paths to the repository and database, as well as the target branch for the commit
pub const UninstallData = struct {
    package_names: []const []const u8,
    branch: [*:0]const u8,

    repo_path: [*:0]const u8,
    root_path: [*:0]const u8,
    database_path: [*:0]const u8,
    prefix_path: [*:0]const u8,

    on_progress: ?UninstallProgressFn = null,
    progress_ctx: ?*anyopaque = null,
    max_retries: u8 = 0,
};

// ── UninstallerFSM ─────────────────────────────────────────────────────────────────────
// Uninstaller state container for fsm data between states
pub const UninstallerMachine = struct {
    data: UninstallData,

    current_package_index: usize,
    retries: u8,

    repo: ?*c_libs.OstreeRepo,
    mtree: ?*c_libs.OstreeMutableTree,

    commit_checksum: ?[*:0]u8 = null,
    previous_commit_checksum: [*c]u8 = null,

    staging_path_c: ?[:0]const u8 = null,

    package_file_map: ?data.FileMap,
    package_checksum: ?[]const u8,

    cancellable: ?*c_libs.GCancellable = null,
    gerror: ?*c_libs.GError = null,

    stack: std.ArrayList(UninstallStateId),
    allocator: std.mem.Allocator,

    // Registers a transition to a new state, adding it to the stack for progress tracking and debugging
    pub fn enter(self: *UninstallerMachine, state_id: UninstallStateId) !void {
        isBroked(self) catch |err| return err;

        try self.stack.append(self.allocator, state_id);
        self.report(state_id);
    }

    // Resets the retry counter before executing a new operation
    pub fn resetRetries(self: *UninstallerMachine) void {
        self.retries = 0;
    }

    // Checks whether the attempt limit for the current uninstallation step has been exhausted
    pub fn exhausted(self: *UninstallerMachine) bool {
        return self.retries > self.data.max_retries;
    }

    fn isBroked(self: *UninstallerMachine) UninstallerError!void {
        if (self.gerror) |err| {
            const is_cancel_error = err.domain == c_libs.g_io_error_quark() and
                err.code == c_libs.G_IO_ERROR_CANCELLED;

            c_libs.g_error_free(err);
            self.gerror = null;

            if (is_cancel_error) {
                if (self.cancellable) |cancellable| c_libs.g_cancellable_cancel(cancellable);
                stateFailed(self);
                return UninstallerError.Cancelled;
            }

            stateFailed(self);
            return UninstallerError.MaxRetriesExceeded;
        }

        const is_cancelled = isCancelRequested() or
            (if (self.cancellable) |cancellable| c_libs.g_cancellable_is_cancelled(cancellable) != 0 else false);

        if (is_cancelled) {
            if (self.cancellable) |cancellable| c_libs.g_cancellable_cancel(cancellable);
            stateFailed(self);
            return UninstallerError.Cancelled;
        }

        if (self.exhausted()) {
            stateFailed(self);
            return UninstallerError.MaxRetriesExceeded;
        }
    }

    pub fn retry(self: *UninstallerMachine, comptime state_fn: anytype) UninstallerError!void {
        if (self.cancellable) |cancellable| {
            if (c_libs.g_cancellable_is_cancelled(cancellable) != 0) {
                stateFailed(self);
                return error.Cancelled;
            }
        }

        if (self.exhausted()) {
            stateFailed(self);
            return error.MaxRetriesExceeded;
        }

        if (self.gerror) |err| {
            c_libs.g_error_free(err);
            self.gerror = null;
        }

        self.retries += 1;

        try self.resetTransaction();
        return state_fn(self);
    }

    // Resets the transaction by aborting any ongoing transaction and preparing a new one. If the transaction cannot be reset, returns an error
    pub fn resetTransaction(self: *UninstallerMachine) UninstallerError!void {
        var gerror: ?*c_libs.GError = null;
        defer if (gerror) |err| c_libs.g_error_free(err);

        _ = c_libs.ostree_repo_abort_transaction(self.repo.?, null, null);
        if (c_libs.ostree_repo_prepare_transaction(self.repo.?, null, null, &gerror) == 0) {
            stateFailed(self);
            return error.RepoOpenFailed;
        }
    }

    pub inline fn unwrap(self: *UninstallerMachine, value: anytype, comptime err: UninstallerError) UninstallerError!@typeInfo(@TypeOf(value)).optional.child {
        return value orelse {
            stateFailed(self);
            return err;
        };
    }

    pub inline fn check(self: *UninstallerMachine, value: anytype, comptime err: UninstallerError) UninstallerError!@typeInfo(@TypeOf(value)).error_union.payload {
        return value catch {
            stateFailed(self);
            return err;
        };
    }

    pub inline fn gcheck(self: *UninstallerMachine, result: c_int, comptime err: UninstallerError) UninstallerError!void {
        if (result == 0) {
            stateFailed(self);
            return err;
        }
    }

    // Releases all resources: native Zig memory, the file hash map, and OSTree system C objects
    pub fn deinit(self: *UninstallerMachine) void {
        if (self.mtree) |mtree| c_libs.g_object_unref(mtree);
        if (self.repo) |repo| c_libs.g_object_unref(repo);

        if (self.commit_checksum != null) c_libs.g_free(self.commit_checksum);
        if (self.previous_commit_checksum != null) c_libs.g_free(self.previous_commit_checksum);

        if (self.staging_path_c) |path| self.allocator.free(path);

        if (self.package_file_map) |*map| data.freeFileMap(@constCast(map), self.allocator);
        if (self.package_checksum) |checksum| self.allocator.free(checksum);

        if (self.gerror) |err| c_libs.g_error_free(err);
        if (self.cancellable) |cancellable| c_libs.g_object_unref(cancellable);

        self.stack.deinit(self.allocator);
    }

    // Reports an uninstallation progress event to the progress callback, if one is set
    pub fn report(self: *UninstallerMachine, event: UninstallStateId) void {
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

            .current_package_index = 0,
            .retries = 0,

            .repo = null,
            .mtree = null,

            .package_file_map = null,
            .package_checksum = null,

            .cancellable = c_libs.g_cancellable_new() orelse return error.OutOfMemory,

            .stack = std.ArrayList(UninstallStateId).empty,
            .allocator = allocator,
        };
        defer machine.deinit();

        try states.stateVerifying(&machine);
    }
};
