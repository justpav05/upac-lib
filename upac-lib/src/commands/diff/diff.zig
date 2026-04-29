// ── Imports ──────────────────────────────────────────────────────────
const states = @import("states.zig");
const stateFailed = states.stateFailed;

const CSlice = ffi.CSlice;
const CPackageDiffEntry = ffi.CPackageDiffEntry;
const CAttributedDiffEntry = ffi.CAttributedDiffEntry;
const DiffStateId = ffi.DiffStateId;

const isCancelRequested = ffi.isCancelRequested;

// ── Public imports ───────────────────────────────────────────────────────────
pub const std = @import("std");
pub const ffi = @import("upac-ffi");
pub const c_libs = ffi.c_libs;
pub const data = @import("upac-data");

// ── Errors ───────────────────────────────────────────────────────────────────
pub const DiffError = error{
    RepoOpenFailed,
    CommitNotFound,
    DiffFailed,
    AllocFailed,
    FileNotFound,
    Cancelled,
};

pub const DiffPackagesData = struct {
    repo_path: [*:0]const u8,
    from_ref: [*:0]const u8,
    to_ref: [*:0]const u8,
};

pub const DiffFilesData = struct {
    repo_path: [*:0]const u8,
    from_ref: [*:0]const u8,
    to_ref: [*:0]const u8,
    db_path: []const u8,
};

pub const DiffMachine = struct {
    repo: ?*c_libs.OstreeRepo = null,

    result_packages: ?[]CPackageDiffEntry = null,
    result_files: ?[]CAttributedDiffEntry = null,

    cancellable: ?*c_libs.GCancellable = null,
    gerror: ?*c_libs.GError = null,

    stack: std.ArrayList(DiffStateId),
    allocator: std.mem.Allocator,

    pub fn enter(self: *DiffMachine, state_id: DiffStateId) !void {
        isBroked(self) catch |err| return err;

        try self.stack.append(self.allocator, state_id);
    }

    fn isBroked(self: *DiffMachine) DiffError!void {
        if (self.gerror) |err| {
            const is_cancel = err.domain == c_libs.g_io_error_quark() and
                err.code == c_libs.G_IO_ERROR_CANCELLED;
            c_libs.g_error_free(err);
            self.gerror = null;
            stateFailed(self);
            return if (is_cancel) DiffError.Cancelled else DiffError.DiffFailed;
        }

        if (isCancelRequested() or
            (if (self.cancellable) |c| c_libs.g_cancellable_is_cancelled(c) != 0 else false))
        {
            if (self.cancellable) |c| c_libs.g_cancellable_cancel(c);
            stateFailed(self);
            return DiffError.Cancelled;
        }
    }

    pub inline fn unwrap(self: *DiffMachine, value: anytype, comptime err: DiffError) DiffError!@typeInfo(@TypeOf(value)).optional.child {
        return value orelse {
            stateFailed(self);
            return err;
        };
    }

    pub inline fn check(self: *DiffMachine, value: anytype, comptime err: DiffError) DiffError!@typeInfo(@TypeOf(value)).error_union.payload {
        return value catch {
            stateFailed(self);
            return err;
        };
    }

    pub fn deinit(self: *DiffMachine) void {
        if (self.repo) |repo| c_libs.g_object_unref(repo);
        if (self.gerror) |err| c_libs.g_error_free(err);
        if (self.cancellable) |c| c_libs.g_object_unref(c);
        self.stack.deinit(self.allocator);
    }

    pub fn runPackages(diff_data: DiffPackagesData, allocator: std.mem.Allocator) DiffError![]CPackageDiffEntry {
        var machine = DiffMachine{
            .cancellable = c_libs.g_cancellable_new() orelse return DiffError.Cancelled,
            .stack = std.ArrayList(DiffStateId).empty,
            .allocator = allocator,
        };
        defer machine.deinit();

        try states.stateOpenRepo(&machine, diff_data.repo_path);
        try states.stateDiffPackages(&machine, diff_data.from_ref, diff_data.to_ref);

        return machine.result_packages orelse &.{};
    }

    pub fn runFiles(diff_data: DiffFilesData, allocator: std.mem.Allocator) DiffError![]CAttributedDiffEntry {
        var machine = DiffMachine{
            .cancellable = c_libs.g_cancellable_new() orelse return DiffError.Cancelled,
            .stack = std.ArrayList(DiffStateId).empty,
            .allocator = allocator,
        };
        defer machine.deinit();

        try states.stateOpenRepo(&machine, diff_data.repo_path);
        try states.stateDiffFilesAttributed(&machine, diff_data.from_ref, diff_data.to_ref, diff_data.db_path);

        return machine.result_files orelse &.{};
    }
};
