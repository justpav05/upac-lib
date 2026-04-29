// ── Imports ─────────────────────────────────────────────────────────────────────
const CSlice = ffi.CSlice;
const CommitEntry = ffi.CommitEntry;

const RollbackStateId = ffi.RollbackStateId;
const RollbackProgressFn = ffi.RollbackProgressFn;

const states = @import("states.zig");
const stateFailed = states.stateFailed;
const stateVerifying = states.stateVerifying;

const utils = @import("utils.zig");

// ──Public imports ─────────────────────────────────────────────────────────────────────
pub const std = @import("std");
pub const ffi = @import("upac-ffi");
const isCancelRequested = ffi.isCancelRequested;

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

pub const RollbackData = struct {
    repo_path: [*:0]const u8,
    root_path: [*:0]const u8,
    prefix_path: [*:0]const u8,
    branch: [*:0]const u8,
    commit_hash: [*:0]const u8,

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

    stack: std.ArrayList(RollbackStateId),
    allocator: std.mem.Allocator,

    pub fn enter(self: *RollbackMachine, state_id: RollbackStateId) !void {
        isBroked(self) catch |err| return err;

        try self.stack.append(self.allocator, state_id);
        self.report(state_id);
    }

    pub fn resetRetries(self: *RollbackMachine) void {
        self.retries = 0;
    }

    pub fn exhausted(self: *RollbackMachine) bool {
        return self.retries > self.data.max_retries;
    }

    fn isBroked(self: *RollbackMachine) RollbackError!void {
        if (self.gerror) |err| {
            const is_cancel_error = err.domain == c_libs.g_io_error_quark() and
                err.code == c_libs.G_IO_ERROR_CANCELLED;

            c_libs.g_error_free(err);
            self.gerror = null;

            if (is_cancel_error) {
                if (self.cancellable) |cancellable| c_libs.g_cancellable_cancel(cancellable);
                stateFailed(self);
                return RollbackError.Cancelled;
            }

            stateFailed(self);
            return RollbackError.MaxRetriesExceeded;
        }

        const is_cancelled = isCancelRequested() or
            (if (self.cancellable) |cancellable| c_libs.g_cancellable_is_cancelled(cancellable) != 0 else false);

        if (is_cancelled) {
            if (self.cancellable) |cancellable| c_libs.g_cancellable_cancel(cancellable);
            stateFailed(self);
            return RollbackError.Cancelled;
        }

        if (self.exhausted()) {
            stateFailed(self);
            return RollbackError.MaxRetriesExceeded;
        }
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

        self.stack.deinit(self.allocator);
    }

    pub fn run(data: RollbackData, allocator: std.mem.Allocator) !void {
        var machine = RollbackMachine{
            .data = data,

            .retries = 0,

            .stack = std.ArrayList(RollbackStateId).empty,
            .cancellable = c_libs.g_cancellable_new() orelse return RollbackError.OutOfMemory,
            .allocator = allocator,
        };
        defer machine.deinit();

        try states.stateVerifying(&machine);
    }
};
