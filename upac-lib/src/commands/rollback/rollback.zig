// ── Imports ─────────────────────────────────────────────────────────────────────
const CSlice = ffi.CSlice;
const CommitEntry = ffi.CommitEntry;

const RollbackStateId = ffi.RollbackStateId;
const RollbackProgressFn = ffi.RollbackProgressFn;

const states = @import("states.zig");
const stateFailed = states.stateFailed;
const stateVerifying = states.stateVerifying;

const utils = @import("utils.zig");
const onCancelSignal = utils.onCancelSignal;
const signalLoopThread = utils.signalLoopThread;

// ──Public imports ─────────────────────────────────────────────────────────────────────
pub const std = @import("std");
pub const ffi = @import("upac-ffi");
pub const c_libs = ffi.c_libs;

// ── Errors ─────────────────────────────────────────────────────────────────────
// Specific rollback errors: failure to open the repository, missing specified commit, or failure to compute the difference between versions
pub const RollbackError = error{
    RepoOpenFailed,
    PathNotFound,
    RepoTransactionFailed,
    CommitNotFound,
    RollbackFailed,
    StagingFailed,
    SwapFailed,
    CleanupFailed,
    AllocZFailed,
    OutOfMemory,
    Cancelled,
    MaxRetriesExceeded,
};

var cancel_requested = std.atomic.Value(bool).init(false);

fn installSignalHandler(sig: c_int) callconv(.C) void {
    _ = sig;
    cancel_requested.store(true, .release);
}

pub const RollbackData = struct {
    repo_path: [*:0]u8,
    root_path: [*:0]u8,
    prefix_path: [*:0]u8,

    branch: [*:0]u8,
    commit_hash: [*:0]u8,

    on_progress: ?RollbackProgressFn = null,
    progress_ctx: ?*anyopaque = null,

    max_retries: u8 = 0,
};

// ── Rollback ────────────────────────────────────────────────────────────────────
pub const RollbackMachine = struct {
    data: RollbackData,
    retries: u8,

    repo: ?*c_libs.OstreeRepo = null,
    resolved_checksum: ?[*:0]u8 = null,

    staging_path_c: ?[:0]const u8 = null,

    cancellable: ?*c_libs.GCancellable = null,
    gerror: ?*c_libs.GError = null,

    signal_loop: ?*c_libs.GMainLoop = null,
    signal_thread: ?std.Thread = null,

    stack: std.ArrayList(RollbackStateId),
    allocator: std.mem.Allocator,

    pub fn enter(self: *RollbackMachine, state_id: RollbackStateId) !void {
        if (self.cancellable) |cancellable| {
            if (c_libs.g_cancellable_is_cancelled(cancellable) != 0) {
                stateFailed(self);
                return error.Cancelled;
            }
        }

        try self.stack.append(self.allocator, state_id);
        self.report(state_id);
    }

    pub fn resetRetries(self: *RollbackMachine) void {
        self.retries = 0;
    }

    pub fn exhausted(self: *RollbackMachine) bool {
        return self.retries > self.data.max_retries;
    }

    pub fn retry(self: *RollbackMachine, comptime state_fn: anytype) RollbackError!void {
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

        return state_fn(self);
    }

    // Reports an installation progress event to the progress callback, if one is set
    pub fn report(self: *RollbackMachine, event: RollbackStateId) void {
        const cb = self.data.on_progress orelse return;
        cb(event, CSlice.fromSlice(std.mem.span(self.data.commit_hash)), self.data.progress_ctx);
    }

    pub fn unwrap(self: *RollbackMachine, value: anytype, comptime err: RollbackError) RollbackError!@typeInfo(@TypeOf(value)).optional.child {
        return value orelse {
            stateFailed(self);
            return err;
        };
    }

    pub inline fn check(self: *RollbackMachine, value: anytype, comptime err: RollbackError) RollbackError!@typeInfo(@TypeOf(value)).error_union.payload {
        return value catch {
            stateFailed(self);
            return err;
        };
    }

    pub fn gcheck(self: *RollbackMachine, result: c_int, comptime err: RollbackError) RollbackError!void {
        if (result == 0) {
            stateFailed(self);
            return err;
        }
    }

    pub fn deinit(self: *RollbackMachine) void {
        if (self.repo) |repo| c_libs.g_object_unref(repo);
        if (self.resolved_checksum) |checksum| c_libs.g_free(@ptrCast(checksum));

        if (self.staging_path_c) |path| self.allocator.free(path);

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

        self.stack.deinit(self.allocator);
    }

    pub fn run(data: RollbackData, allocator: std.mem.Allocator) !void {
        const sigint_src = c_libs.g_unix_signal_source_new(std.posix.SIG.INT);
        const sigterm_src = c_libs.g_unix_signal_source_new(std.posix.SIG.TERM);

        const signal_ctx = c_libs.g_main_context_new();
        defer c_libs.g_main_context_unref(signal_ctx);

        var machine = RollbackMachine{
            .data = data,

            .retries = 0,

            .stack = std.ArrayList(RollbackStateId).empty,
            .cancellable = c_libs.g_cancellable_new() orelse return RollbackError.OutOfMemory,
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
