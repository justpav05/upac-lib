// ── Imports ─────────────────────────────────────────────────────────────────────
const CPackageMeta = ffi.CPackageMeta;
const CCommitEntry = ffi.CCommitEntry;
const ListStateId = ffi.ListStateId;

const states = @import("states.zig");
const stateFailed = states.stateFailed;

const isCancelRequested = ffi.isCancelRequested;

// ── Public imports ───────────────────────────────────────────────────────────
pub const std = @import("std");
pub const ffi = @import("upac-ffi");
pub const c_libs = ffi.c_libs;

pub const data = @import("upac-data");

pub const ListError = error{
    RepoOpenFailed,
    CommitNotFound,
    AllocFailed,
    Cancelled,
    MaxRetriesExceeded,
};

pub const ListPackagesData = struct {
    repo_path: [*:0]const u8,
    branch: [*:0]const u8,
    db_path: []const u8,
};

pub const ListCommitsData = struct {
    repo_path: [*:0]const u8,
    branch: [*:0]const u8,
};

pub const ListMachine = struct {
    repo: ?*c_libs.OstreeRepo = null,

    result_packages: ?[]CPackageMeta = null,
    result_commits: ?[]CCommitEntry = null,

    cancellable: ?*c_libs.GCancellable = null,
    gerror: ?*c_libs.GError = null,

    stack: std.ArrayList(ListStateId),
    allocator: std.mem.Allocator,

    pub fn enter(self: *ListMachine, state_id: ListStateId) !void {
        isBroked(self) catch |err| return err;

        try self.stack.append(self.allocator, state_id);
    }

    fn isBroked(self: *ListMachine) ListError!void {
        if (self.gerror) |err| {
            const is_cancel_error = err.domain == c_libs.g_io_error_quark() and
                err.code == c_libs.G_IO_ERROR_CANCELLED;

            c_libs.g_error_free(err);
            self.gerror = null;

            if (is_cancel_error) {
                if (self.cancellable) |cancellable| c_libs.g_cancellable_cancel(cancellable);
                stateFailed(self);
                return ListError.Cancelled;
            }

            stateFailed(self);
            return ListError.MaxRetriesExceeded;
        }

        const is_cancelled = isCancelRequested() or
            (if (self.cancellable) |cancellable| c_libs.g_cancellable_is_cancelled(cancellable) != 0 else false);

        if (is_cancelled) {
            if (self.cancellable) |cancellable| c_libs.g_cancellable_cancel(cancellable);
            stateFailed(self);
            return ListError.Cancelled;
        }
    }

    pub inline fn unwrap(self: *ListMachine, value: anytype, comptime err: ListError) ListError!@typeInfo(@TypeOf(value)).optional.child {
        return value orelse {
            stateFailed(self);
            return err;
        };
    }

    pub inline fn check(self: *ListMachine, value: anytype, comptime err: ListError) ListError!@typeInfo(@TypeOf(value)).error_union.payload {
        return value catch {
            stateFailed(self);
            return err;
        };
    }

    pub fn deinit(self: *ListMachine) void {
        if (self.repo) |repo| c_libs.g_object_unref(repo);
        if (self.gerror) |err| c_libs.g_error_free(err);
        if (self.cancellable) |cancellable| c_libs.g_object_unref(cancellable);

        self.stack.deinit(self.allocator);
    }

    pub fn runPackages(list_data: ListPackagesData, allocator: std.mem.Allocator) ListError![]CPackageMeta {
        var machine = ListMachine{
            .cancellable = c_libs.g_cancellable_new() orelse return ListError.Cancelled,
            .stack = std.ArrayList(ListStateId).empty,
            .allocator = allocator,
        };
        defer machine.deinit();

        try states.stateOpenRepo(&machine, list_data.repo_path);
        try states.stateListPackages(&machine, list_data.branch, list_data.db_path);

        return machine.result_packages orelse &.{};
    }

    pub fn runCommits(list_data: ListCommitsData, allocator: std.mem.Allocator) ListError![]CCommitEntry {
        var machine = ListMachine{
            .cancellable = c_libs.g_cancellable_new() orelse return ListError.Cancelled,
            .stack = std.ArrayList(ListStateId).empty,
            .allocator = allocator,
        };
        defer machine.deinit();

        try states.stateOpenRepo(&machine, list_data.repo_path);
        try states.stateListCommits(&machine, list_data.branch);

        return machine.result_commits orelse &.{};
    }
};
