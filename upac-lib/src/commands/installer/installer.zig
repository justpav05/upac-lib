// ── Imports ─────────────────────────────────────────────────────────────────────
const CSlice = ffi.CSlice;

const InstallStateId = ffi.InstallStateId;
const InstallProgressFn = ffi.InstallProgressFn;

const Package = ffi.Package;
const PackageMeta = ffi.PackageMeta;

const isCancelRequested = ffi.isCancelRequested;

const states = @import("states.zig");
const stateFailed = states.stateFailed;

const utils = @import("utils.zig");
// ── Public imports ─────────────────────────────────────────────────────────────────────
pub const std = @import("std");

pub const ffi = @import("upac-ffi");
pub const c_libs = ffi.c_libs;

pub const data = @import("upac-data");

// ── Errors ────────────────────────────────────────────────────────────────────
//
pub const InstallerError = error{
    // Special errors
    AlreadyInstalled,
    PackageNotFound,
    NotEnoughSpace,
    CheckSpaceFailed,
    WriteDatabaseFailed,
    CollectFileChecksumsFailed,
    MakeFailed,
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

pub const InstallEntry = struct {
    package: Package,
    temp_path: []const u8,
    checksum: []const u8,
};

// ── InstallData ───────────────────────────────────────────────────────────────
// A container structure holding all installation parameters: package metadata, paths to the repository and database, as well as retry limits
pub const InstallData = struct {
    packages: []const InstallEntry,
    branch: [*:0]u8,

    repo_path: [*:0]u8,
    root_path: [*:0]u8,
    database_path: [*:0]u8,
    prefix_path: [*:0]u8,

    on_progress: ?InstallProgressFn = null,
    progress_ctx: ?*anyopaque = null,

    max_retries: u8 = 0,
};

// ── InstallerMachine ──────────────────────────────────────────────────────────
// The main structure of a finite-state machine, with information persistence between states
pub const InstallerMachine = struct {
    data: InstallData,

    current_package_index: usize = 0,
    retries: u8,

    repo: ?*c_libs.OstreeRepo,
    mtree: ?*c_libs.OstreeMutableTree,

    commit_checksum: [*c]u8 = null,
    previous_commit_checksum: [*c]u8 = null,

    staging_path_c: ?[:0]const u8 = null,

    cancellable: ?*c_libs.GCancellable = null,
    gerror: ?*c_libs.GError = null,

    stack: std.ArrayList(InstallStateId),
    allocator: std.mem.Allocator,

    // Registers a transition to a new state, saving it to the stack. This allows for the reconstruction of the sequence of actions during debugging
    pub fn enter(self: *InstallerMachine, state_id: InstallStateId) !void {
        isBroked(self) catch |err| return err;

        try self.stack.append(self.allocator, state_id);
        self.report(state_id);
    }

    // Resets the attempt counter before starting a new operation
    pub fn resetRetries(self: *InstallerMachine) void {
        self.retries = 0;
    }

    // Checks whether the retry limit for the current step has been exceeded. If the limit is exhausted, the installation is interrupted
    pub fn exhausted(self: *InstallerMachine) bool {
        return self.retries > self.data.max_retries;
    }

    fn isBroked(self: *InstallerMachine) InstallerError!void {
        if (self.gerror) |err| {
            const is_cancel_error = err.domain == c_libs.g_io_error_quark() and
                err.code == c_libs.G_IO_ERROR_CANCELLED;

            c_libs.g_error_free(err);
            self.gerror = null;

            if (is_cancel_error) {
                if (self.cancellable) |cancellable| c_libs.g_cancellable_cancel(cancellable);
                stateFailed(self);
                return InstallerError.Cancelled;
            }

            stateFailed(self);
            return InstallerError.MaxRetriesExceeded;
        }

        const is_cancelled = ffi.isCancelRequested() or
            (if (self.cancellable) |cancellable| c_libs.g_cancellable_is_cancelled(cancellable) != 0 else false);

        if (is_cancelled) {
            if (self.cancellable) |cancellable| c_libs.g_cancellable_cancel(cancellable);
            stateFailed(self);
            return InstallerError.Cancelled;
        }

        if (self.exhausted()) {
            stateFailed(self);
            return InstallerError.MaxRetriesExceeded;
        }
    }

    pub fn retry(self: *InstallerMachine, comptime state_fn: anytype) InstallerError!void {
        self.retries += 1;

        try self.resetTransaction();
        return state_fn(self);
    }

    // Resets the transaction by aborting any ongoing transaction and preparing a new one. If the transaction cannot be reset, returns an error
    pub fn resetTransaction(self: *InstallerMachine) InstallerError!void {
        var gerror: ?*c_libs.GError = null;
        defer if (gerror) |err| c_libs.g_error_free(err);
        const repo = try self.unwrap(self.repo, InstallerError.RepoOpenFailed);

        _ = c_libs.ostree_repo_abort_transaction(repo, null, null);
        if (c_libs.ostree_repo_prepare_transaction(repo, null, null, &gerror) == 0) return InstallerError.RepoOpenFailed;
    }

    pub inline fn unwrap(self: *InstallerMachine, value: anytype, comptime err: InstallerError) InstallerError!@typeInfo(@TypeOf(value)).optional.child {
        return value orelse {
            stateFailed(self);
            return err;
        };
    }

    pub inline fn check(self: *InstallerMachine, value: anytype, comptime err: InstallerError) InstallerError!@typeInfo(@TypeOf(value)).error_union.payload {
        return value catch {
            stateFailed(self);
            return err;
        };
    }

    pub inline fn gcheck(self: *InstallerMachine, result: c_int, comptime err: InstallerError) InstallerError!void {
        if (result == 0) {
            stateFailed(self);
            return err;
        }
    }

    pub fn prefixPathZ(self: *InstallerMachine) InstallerError![:0]const u8 {
        return self.check(std.fs.path.joinZ(self.allocator, &.{ std.mem.span(self.data.root_path), std.mem.span(self.data.prefix_path) }), InstallerError.AllocZFailed);
    }

    // Correct memory deallocation function
    pub fn deinit(self: *InstallerMachine) void {
        if (self.mtree) |mtree| c_libs.g_object_unref(mtree);
        if (self.repo) |repo| c_libs.g_object_unref(repo);

        if (self.commit_checksum != null) c_libs.g_free(self.commit_checksum);
        if (self.previous_commit_checksum != null) c_libs.g_free(self.previous_commit_checksum);

        if (self.staging_path_c) |ptr| self.allocator.free(ptr);

        if (self.gerror) |ptr| c_libs.g_error_free(ptr);
        if (self.cancellable) |cancellable| c_libs.g_object_unref(cancellable);

        self.stack.deinit(self.allocator);
    }

    // Reports an installation progress event to the progress callback, if one is set
    pub fn report(self: *InstallerMachine, event: InstallStateId) void {
        const cb = self.data.on_progress orelse return;
        const name = if (self.current_package_index < self.data.packages.len)
            self.data.packages[self.current_package_index].package.meta.name
        else
            "";
        cb(event, CSlice.fromSlice(name), self.data.progress_ctx);
    }

    // Initializes the machine, creates the state stack, and launches the first stage—verification
    pub fn run(install_data: InstallData, allocator: std.mem.Allocator) InstallerError!void {
        var machine = InstallerMachine{
            .data = install_data,

            .current_package_index = 0,
            .retries = 0,

            .repo = null,
            .mtree = null,

            .cancellable = c_libs.g_cancellable_new() orelse return InstallerError.OutOfMemory,

            .stack = std.ArrayList(InstallStateId).empty,
            .allocator = allocator,
        };
        defer machine.deinit();

        try states.stateVerifying(&machine);
    }
};
