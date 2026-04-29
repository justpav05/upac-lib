// ── Imports ─────────────────────────────────────────────────────────────────────
const rollback = @import("rollback.zig");
const std = rollback.std;
const c_libs = rollback.c_libs;

const RollbackError = rollback.RollbackError;
// ── Helpers functions ─────────────────────────────────────────────────────────────────────
// Resolve a temporary directory adjacent to root_path (e.g. /usr → /usr-rollback-<timestamp>)
pub fn resolveStagingDir(root_path: []const u8, prefix: []const u8, allocator: std.mem.Allocator) RollbackError![:0]u8 {
    var suffix_buf: [64]u8 = undefined;

    const timestamp = std.time.milliTimestamp();
    const suffix = std.fmt.bufPrint(&suffix_buf, "{s}-rollback-{d}", .{ prefix, timestamp }) catch return error.AllocZFailed;

    return std.fs.path.joinZ(allocator, &.{ root_path, suffix }) catch return error.AllocZFailed;
}
// Resolve a root dir (e.g. /usr → /usr-rollback-<timestamp>)
pub fn resolveRootDir(root_path: []const u8, prefix: []const u8, allocator: std.mem.Allocator) RollbackError![:0]const u8 {
    return std.fs.path.joinZ(allocator, &.{ root_path, prefix }) catch return error.AllocZFailed;
}

// Performs a clean OSTree checkout of the resolved commit into the staging directory
fn checkoutToStaging(repo: *c_libs.OstreeRepo, resolved_checksum: [*:0]const u8, staging_path: [:0]const u8) RollbackError!void {
    var gerror: ?*c_libs.GError = null;

    var checkout_options = std.mem.zeroes(c_libs.OstreeRepoCheckoutAtOptions);
    checkout_options.mode = c_libs.OSTREE_REPO_CHECKOUT_MODE_NONE;
    checkout_options.overwrite_mode = c_libs.OSTREE_REPO_CHECKOUT_OVERWRITE_NONE;

    if (c_libs.ostree_repo_checkout_at(repo, &checkout_options, std.c.AT.FDCWD, staging_path.ptr, resolved_checksum, null, &gerror) == 0) {
        if (gerror) |err| c_libs.g_error_free(err);
        return error.StagingFailed;
    }
}

// Atomically exchanges two directory paths using the Linux renameat2 syscall with RENAME_EXCHANGE.
fn atomicSwap(root_path_c: [:0]const u8, staging_path: [:0]const u8) RollbackError!void {
    const RENAME_EXCHANGE = 2;
    const AT_FDCWD = -100;

    const result = std.os.linux.syscall5(.renameat2, @bitCast(@as(isize, AT_FDCWD)), @intFromPtr(staging_path.ptr), @bitCast(@as(isize, AT_FDCWD)), @intFromPtr(root_path_c.ptr), RENAME_EXCHANGE);

    const errno_value = std.os.linux.E.init(result);
    if (errno_value != .SUCCESS) return error.SwapFailed;
}

// Removes the old root tree which now resides at the staging path after the swap.
fn cleanupOldRoot(staging_path: [:0]const u8) RollbackError!void {
    std.fs.deleteTreeAbsolute(staging_path) catch |err| return err;
}

// Moves the OSTree branch ref to point at the target commit via a transaction
fn updateBranchRef(repo: *c_libs.OstreeRepo, branch_c: [:0]const u8, resolved_checksum: [*:0]const u8) RollbackError!void {
    var gerror: ?*c_libs.GError = null;

    if (c_libs.ostree_repo_prepare_transaction(repo, null, null, &gerror) == 0) {
        if (gerror) |err| c_libs.g_error_free(err);
        return error.RollbackFailed;
    }

    c_libs.ostree_repo_transaction_set_ref(repo, null, branch_c.ptr, resolved_checksum);

    if (c_libs.ostree_repo_commit_transaction(repo, null, null, &gerror) == 0) {
        if (gerror) |err| c_libs.g_error_free(err);
        _ = c_libs.ostree_repo_abort_transaction(repo, null, null);
        return error.RollbackFailed;
    }
}
