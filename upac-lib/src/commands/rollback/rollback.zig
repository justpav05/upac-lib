// ── Imports ─────────────────────────────────────────────────────────────────────
const CSlice = ffi.CSlice;
const CommitEntry = ffi.CommitEntry;

const RollbackStateId = ffi.RollbackStateId;
const RollbackProgressFn = ffi.RollbackProgressFn;

const states = @import("states.zig");
const stateFailed = states.stateFailed;
const stateVerifying = states.stateVerifying;

// ── Imports symbols ─────────────────────────────────────────────────────────────────────
pub usingnamespace @import("symbols.zig");

// ──Public imports ─────────────────────────────────────────────────────────────────────
pub const std = @import("std");
pub const ffi = @import("upac-ffi");

pub const file = @import("upac-file");
pub const c_libs = file.c_libs;

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
    repo_path: []const u8,
    root_path: []const u8,

    branch: []const u8,
    prefix: []const u8,

    commit_hash: []const u8,
    on_progress: ?RollbackProgressFn = null,
    progress_ctx: ?*anyopaque = null,

    max_retries: u8 = 0,
};

// ── Rollback ────────────────────────────────────────────────────────────────────
pub const RollbackMachine = struct {
    data: RollbackData,
    retries: u8,

    repo: ?*c_libs.OstreeRepo = null,
    branch_c: ?[:0]const u8 = null,

    resolved_checksum: ?[*:0]u8 = null,
    staging_path: ?[:0]const u8 = null,

    stack: std.ArrayList(RollbackStateId),
    cancellable: ?*c_libs.GCancellable = null,
    gerror: ?*c_libs.GError = null,
    signal_loop: ?*c_libs.GMainLoop = null,
    signal_thread: ?std.Thread = null,
    allocator: std.mem.Allocator,

    pub fn enter(self: *RollbackMachine, state_id: RollbackStateId) !void {
        if (self.cancellable) |cancellable| {
            if (c_libs.g_cancellable_is_cancelled(cancellable) != 0) {
                stateFailed(self);
                return RollbackError.Cancelled;
            }
        }

        try self.stack.append(state_id);
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
                return RollbackError.Cancelled;
            }
        }

        if (self.exhausted()) {
            stateFailed(self);
            return RollbackError.MaxRetriesExceeded;
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
        cb(event, CSlice.fromSlice(self.data.commit_hash), self.data.progress_ctx);
    }

    pub fn deinit(self: *RollbackMachine) void {
        if (self.staging_path) |path| self.allocator.free(path);
        if (self.resolved_checksum) |checksum| c_libs.g_free(@ptrCast(checksum));

        if (self.branch_c) |branch| self.allocator.free(branch);
        if (self.repo) |repo| c_libs.g_object_unref(repo);

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

    pub fn run(data: RollbackData, allocator: std.mem.Allocator) !void {
        const sigint_src = c_libs.g_unix_signal_source_new(std.posix.SIG.INT);
        const sigterm_src = c_libs.g_unix_signal_source_new(std.posix.SIG.TERM);

        const signal_ctx = c_libs.g_main_context_new();
        defer c_libs.g_main_context_unref(signal_ctx);

        var machine = RollbackMachine{
            .data = data,

            .retries = 0,

            .stack = std.ArrayList(RollbackStateId).init(allocator),
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

// ── Helpers functions ─────────────────────────────────────────────────────────────────────
// Resolve a temporary directory adjacent to root_path (e.g. /usr → /usr-rollback-<timestamp>)
pub fn resolveStagingDir(root_path: []const u8, allocator: std.mem.Allocator) ![:0]const u8 {
    const root_path_c = try std.fmt.allocPrintZ(allocator, "{s}", .{root_path});
    defer allocator.free(root_path_c);

    const timestamp = std.time.milliTimestamp();
    const staging_path_c = if (root_path_c[root_path_c.len - 1] == '/')
        try std.fmt.allocPrintZ(allocator, "{s}-rollback-{d}", .{ root_path_c[0 .. root_path_c.len - 1], timestamp })
    else
        try std.fmt.allocPrintZ(allocator, "{s}-rollback-{d}", .{ root_path_c, timestamp });
    errdefer allocator.free(staging_path_c);

    return staging_path_c;
}

// Resolve a root dir (e.g. /usr → /usr-rollback-<timestamp>)
pub fn resolveStagingRootDir(root_path: []const u8, prefix: []const u8, allocator: std.mem.Allocator) ![:0]const u8 {
    const root_path_c = try std.fmt.allocPrintZ(allocator, "{s}", .{root_path});
    defer allocator.free(root_path_c);

    const staging_root_path_c = if (root_path_c[root_path_c.len - 1] == '/')
        try std.fmt.allocPrintZ(allocator, "{s}/{s}", .{ root_path_c[0 .. root_path_c.len - 1], prefix })
    else
        try std.fmt.allocPrintZ(allocator, "{s}/{s}", .{ root_path_c, prefix });
    errdefer allocator.free(staging_root_path_c);

    return staging_root_path_c;
}

// Resolve a temp dir with usr dir (e.g. /usr → /usr-rollback-<timestamp>)
pub fn resolveStagingPrefixDir(staging_path: []const u8, prefix: []const u8, allocator: std.mem.Allocator) ![:0]const u8 {
    const staging_usr_path_c = try std.fmt.allocPrintZ(allocator, "{s}/{s}", .{ staging_path, prefix });
    errdefer allocator.free(staging_usr_path_c);

    return staging_usr_path_c;
}

// Performs a clean OSTree checkout of the resolved commit into the staging directory
fn checkoutToStaging(repo: *c_libs.OstreeRepo, resolved_checksum: [*:0]const u8, staging_path: [:0]const u8) !void {
    var gerror: ?*c_libs.GError = null;

    var checkout_options = std.mem.zeroes(c_libs.OstreeRepoCheckoutAtOptions);
    checkout_options.mode = c_libs.OSTREE_REPO_CHECKOUT_MODE_NONE;
    checkout_options.overwrite_mode = c_libs.OSTREE_REPO_CHECKOUT_OVERWRITE_NONE;

    if (c_libs.ostree_repo_checkout_at(repo, &checkout_options, std.c.AT.FDCWD, staging_path.ptr, resolved_checksum, null, &gerror) == 0) {
        if (gerror) |err| c_libs.g_error_free(err);
        return RollbackError.StagingFailed;
    }
}

// Atomically exchanges two directory paths using the Linux renameat2 syscall with RENAME_EXCHANGE.
fn atomicSwap(root_path_c: [:0]const u8, staging_path: [:0]const u8) !void {
    const RENAME_EXCHANGE = 2;
    const AT_FDCWD = -100;

    const result = std.os.linux.syscall5(.renameat2, @bitCast(@as(isize, AT_FDCWD)), @intFromPtr(staging_path.ptr), @bitCast(@as(isize, AT_FDCWD)), @intFromPtr(root_path_c.ptr), RENAME_EXCHANGE);

    const errno_value = std.os.linux.E.init(result);
    if (errno_value != .SUCCESS) return RollbackError.SwapFailed;
}

// Removes the old root tree which now resides at the staging path after the swap.
fn cleanupOldRoot(staging_path: [:0]const u8) !void {
    std.fs.deleteTreeAbsolute(staging_path) catch |err| return err;
}

// Moves the OSTree branch ref to point at the target commit via a transaction
fn updateBranchRef(repo: *c_libs.OstreeRepo, branch_c: [:0]const u8, resolved_checksum: [*:0]const u8) !void {
    var gerror: ?*c_libs.GError = null;

    if (c_libs.ostree_repo_prepare_transaction(repo, null, null, &gerror) == 0) {
        if (gerror) |err| c_libs.g_error_free(err);
        return RollbackError.RollbackFailed;
    }

    c_libs.ostree_repo_transaction_set_ref(repo, null, branch_c.ptr, resolved_checksum);

    if (c_libs.ostree_repo_commit_transaction(repo, null, null, &gerror) == 0) {
        if (gerror) |err| c_libs.g_error_free(err);
        _ = c_libs.ostree_repo_abort_transaction(repo, null, null);
        return RollbackError.RollbackFailed;
    }
}

fn onCancelSignal(user_data: c_libs.gpointer) callconv(.C) c_libs.gboolean {
    const cancellable = @as(*c_libs.GCancellable, @ptrCast(@alignCast(user_data)));
    c_libs.g_cancellable_cancel(cancellable);
    return c_libs.G_SOURCE_REMOVE;
}

fn signalLoopThread(loop: *c_libs.GMainLoop) void {
    c_libs.g_main_loop_run(loop);
}
