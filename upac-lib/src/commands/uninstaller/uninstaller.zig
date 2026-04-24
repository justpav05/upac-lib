// ── Imports ─────────────────────────────────────────────────────────────────────
const data = @import("upac-data");

const UninstallStateId = ffi.UninstallStateId;
const UninstallProgressFn = ffi.UninstallProgressFn;

const file = @import("upac-file");

const states = @import("states.zig");
const utils = @import("utils.zig");

const onCancelSignal = utils.onCancelSignal;
const signalLoopThread = utils.signalLoopThread;

// ── Public imports ─────────────────────────────────────────────────────────────────────
pub const std = @import("std");
pub const ffi = @import("upac-ffi");
pub const CSlice = ffi.CSlice;

pub const c_libs = file.c_libs;

pub const stateFailed = states.stateFailed;

// ── Imports symbols ─────────────────────────────────────────────────────────────────────
pub usingnamespace @import("symbols.zig");

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
    branch: [*:0]u8,

    repo_path: [*:0]u8,
    root_path: [*:0]u8,
    database_path: [*:0]u8,
    prefix_path: [*:0]u8,

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
    previous_commit_checksum: ?[*:0]u8 = null,

    staging_path_c: ?[:0]const u8 = null,

    package_file_map: ?data.FileMap,
    package_checksum: ?[]const u8,

    cancellable: ?*c_libs.GCancellable = null,
    gerror: ?*c_libs.GError = null,

    signal_loop: ?*c_libs.GMainLoop = null,
    signal_thread: ?std.Thread = null,

    stack: std.ArrayList(UninstallStateId),
    allocator: std.mem.Allocator,

    // Registers a transition to a new state, adding it to the stack for progress tracking and debugging
    pub fn enter(self: *UninstallerMachine, state_id: UninstallStateId) !void {
        if (self.cancellable) |cancellable| {
            if (c_libs.g_cancellable_is_cancelled(cancellable) != 0) {
                stateFailed(self);
                return error.Cancelled;
            }
        }

        try self.stack.append(state_id);
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

    pub inline fn unwrap(self: *UninstallerMachine, value: anytype, comptime err: UninstallerError) UninstallerError!@typeInfo(@TypeOf(value)).Optional.child {
        return value orelse {
            stateFailed(self);
            return err;
        };
    }

    pub inline fn check(self: *UninstallerMachine, value: anytype, comptime err: UninstallerError) UninstallerError!@typeInfo(@TypeOf(value)).ErrorUnion.payload {
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

        if (self.commit_checksum) |checksum| c_libs.g_free(@ptrCast(checksum));
        if (self.previous_commit_checksum) |checksum| c_libs.g_free(@ptrCast(checksum));

        if (self.staging_path_c) |path| self.allocator.free(path);

        if (self.package_file_map) |*map| data.freeFileMap(@constCast(map), self.allocator);
        if (self.package_checksum) |checksum| self.allocator.free(checksum);

        if (self.gerror) |err| c_libs.g_error_free(err);
        if (self.cancellable) |cancellable| c_libs.g_object_unref(cancellable);

        if (self.signal_loop) |loop| {
            c_libs.g_main_loop_quit(loop);
        }
        if (self.signal_thread) |tread| {
            tread.join();
            self.signal_thread = null;
        }
        if (self.signal_loop) |loop| {
            c_libs.g_main_loop_unref(loop);
            self.signal_loop = null;
        }

        self.stack.deinit();
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
        const sigint_src = c_libs.g_unix_signal_source_new(std.posix.SIG.INT);
        const sigterm_src = c_libs.g_unix_signal_source_new(std.posix.SIG.TERM);

        const signal_ctx = c_libs.g_main_context_new();
        defer c_libs.g_main_context_unref(signal_ctx);

        var machine = UninstallerMachine{
            .data = uninstall_data,

            .current_package_index = 0,
            .retries = 0,

            .repo = null,
            .mtree = null,

            .package_file_map = null,
            .package_checksum = null,

            .cancellable = c_libs.g_cancellable_new() orelse return error.OutOfMemory,

            .stack = std.ArrayList(UninstallStateId).init(allocator),
            .allocator = allocator,
        };
        defer machine.deinit();

        c_libs.g_source_set_callback(sigint_src, @ptrCast(&onCancelSignal), machine.cancellable, null);
        _ = c_libs.g_source_attach(sigint_src, signal_ctx);
        c_libs.g_source_unref(sigint_src);

        c_libs.g_source_set_callback(sigterm_src, @ptrCast(&onCancelSignal), machine.cancellable, null);
        _ = c_libs.g_source_attach(sigterm_src, signal_ctx);
        c_libs.g_source_unref(sigterm_src);

        machine.signal_loop = c_libs.g_main_loop_new(signal_ctx, 0);
        machine.signal_thread = std.Thread.spawn(.{}, signalLoopThread, .{machine.signal_loop.?}) catch null;

        try states.stateVerifying(&machine);
    }
};
