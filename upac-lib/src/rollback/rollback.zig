// ── Imports ─────────────────────────────────────────────────────────────────────
const std = @import("std");

const file = @import("upac-file");
const c_libs = file.c_libs;

// ── Errors ─────────────────────────────────────────────────────────────────────
// Specific rollback errors: failure to open the repository, missing specified commit, or failure to compute the difference between versions
pub const RollbackError = error{
    RepoOpenFailed,
    CommitNotFound,
    RollbackFailed,
    DiffFailed,
    StagingFailed,
    SwapFailed,
    CleanupFailed,
};

// A structure for storing information about a specific "restore point"
pub const CommitEntry = struct {
    checksum: []const u8,
    subject: []const u8,
};

// Listing of file change types: added, removed, modified
pub const DiffKind = enum { added, removed, modified };

// Description of the specific change: the file path and exactly what happened to it
pub const DiffEntry = struct {
    path: []const u8,
    kind: DiffKind,
};

// ── Rollback ────────────────────────────────────────────────────────────────────
// The primary function of the coordinator — performs an atomic rollback to a target commit.
pub fn rollback(repo_path: []const u8, branch: []const u8, commit_hash: []const u8, root_path: []const u8, allocator: std.mem.Allocator) !void {
    const repo_path_c = try std.fmt.allocPrintZ(allocator, "{s}", .{repo_path});
    defer allocator.free(repo_path_c);
    const branch_c = try std.fmt.allocPrintZ(allocator, "{s}", .{branch});
    defer allocator.free(branch_c);
    const commit_hash_c = try std.fmt.allocPrintZ(allocator, "{s}", .{commit_hash});
    defer allocator.free(commit_hash_c);
    const root_path_c = try std.fmt.allocPrintZ(allocator, "{s}", .{root_path});
    defer allocator.free(root_path_c);

    var gerror: ?*c_libs.GError = null;

    const gfile = c_libs.g_file_new_for_path(repo_path_c.ptr);
    defer c_libs.g_object_unref(gfile);

    const repo = c_libs.ostree_repo_new(gfile);
    defer c_libs.g_object_unref(repo);

    if (c_libs.ostree_repo_open(repo, null, &gerror) == 0) {
        if (gerror) |err| c_libs.g_error_free(err);
        return RollbackError.RepoOpenFailed;
    }

    const resolved_checksum = try resolveCommit(repo.?, commit_hash_c);
    defer c_libs.g_free(@ptrCast(resolved_checksum));

    const staging_path = try createStagingDir(root_path_c, allocator);
    defer allocator.free(staging_path);
    errdefer std.fs.deleteTreeAbsolute(staging_path) catch {};

    try checkoutToStaging(repo.?, resolved_checksum, staging_path);

    try atomicSwap(root_path_c, staging_path);

    try cleanupOldRoot(staging_path);

    try updateBranchRef(repo.?, branch_c, resolved_checksum);
}

// Allows retrieving the change history for a specific branch
pub fn listCommits(repo_path: []const u8, branch: []const u8, allocator: std.mem.Allocator) ![]CommitEntry {
    const repo_path_c = try std.fmt.allocPrintZ(allocator, "{s}", .{repo_path});
    defer allocator.free(repo_path_c);
    const branch_c = try std.fmt.allocPrintZ(allocator, "{s}", .{branch});
    defer allocator.free(branch_c);

    var gerror: ?*c_libs.GError = null;

    const gfile = c_libs.g_file_new_for_path(repo_path_c.ptr);
    defer c_libs.g_object_unref(gfile);

    const repo = c_libs.ostree_repo_new(gfile);
    defer c_libs.g_object_unref(repo);

    if (c_libs.ostree_repo_open(repo, null, &gerror) == 0) {
        if (gerror) |err| c_libs.g_error_free(err);
        return RollbackError.RepoOpenFailed;
    }

    var entries = std.ArrayList(CommitEntry).init(allocator);
    errdefer {
        for (entries.items) |entry| {
            allocator.free(entry.checksum);
            allocator.free(entry.subject);
        }
        entries.deinit();
    }

    var current_checksum: ?[*:0]u8 = null;
    if (c_libs.ostree_repo_resolve_rev(repo, branch_c.ptr, 0, &current_checksum, &gerror) == 0) {
        if (gerror) |err| c_libs.g_error_free(err);
        return entries.toOwnedSlice();
    }

    var checksum = current_checksum;
    while (checksum) |current_cs| {
        var commit_variant: ?*c_libs.GVariant = null;

        if (c_libs.ostree_repo_load_variant(repo, c_libs.OSTREE_OBJECT_TYPE_COMMIT, current_cs, &commit_variant, &gerror) == 0) {
            if (gerror) |err| c_libs.g_error_free(err);
            break;
        }
        defer if (commit_variant) |variant| c_libs.g_variant_unref(variant);

        var subject_variant: ?*c_libs.GVariant = null;
        subject_variant = c_libs.g_variant_get_child_value(commit_variant, 3);
        defer if (subject_variant) |variant| c_libs.g_variant_unref(variant);

        var subject_len: usize = 0;
        const subject_ptr = c_libs.g_variant_get_string(subject_variant, &subject_len);

        try entries.append(CommitEntry{
            .checksum = try allocator.dupe(u8, std.mem.span(current_cs)),
            .subject = try allocator.dupe(u8, subject_ptr[0..subject_len]),
        });

        const parent_checksum = c_libs.ostree_commit_get_parent(commit_variant);
        if (current_checksum != null and current_checksum != checksum)
            c_libs.g_free(@ptrCast(checksum));
        checksum = parent_checksum;
    }

    if (current_checksum) |cs| c_libs.g_free(@ptrCast(cs));
    return entries.toOwnedSlice();
}

// ── Diff ────────────────────────────────────────────────────────────────────────
// Compares two repository states
pub fn diff(repo_path: []const u8, from_ref: []const u8, to_ref: []const u8, allocator: std.mem.Allocator) ![]DiffEntry {
    const repo_path_c = try std.fmt.allocPrintZ(allocator, "{s}", .{repo_path});
    defer allocator.free(repo_path_c);

    const from_ref_c = try std.fmt.allocPrintZ(allocator, "{s}", .{from_ref});
    defer allocator.free(from_ref_c);

    const to_ref_c = try std.fmt.allocPrintZ(allocator, "{s}", .{to_ref});
    defer allocator.free(to_ref_c);

    var gerror: ?*c_libs.GError = null;

    const gfile = c_libs.g_file_new_for_path(repo_path_c.ptr);
    defer c_libs.g_object_unref(gfile);

    const repo = c_libs.ostree_repo_new(gfile);
    defer c_libs.g_object_unref(repo);

    if (c_libs.ostree_repo_open(repo, null, &gerror) == 0) {
        if (gerror) |err| c_libs.g_error_free(err);
        return RollbackError.RepoOpenFailed;
    }

    const timestamp = std.time.milliTimestamp();

    const from_checkout_path = try std.fmt.allocPrintZ(allocator, "/tmp/upac_diff_from_{d}", .{timestamp});
    defer allocator.free(from_checkout_path);
    defer std.fs.deleteTreeAbsolute(from_checkout_path) catch {};

    const to_checkout_path = try std.fmt.allocPrintZ(allocator, "/tmp/upac_diff_to_{d}", .{timestamp + 1});
    defer allocator.free(to_checkout_path);
    defer std.fs.deleteTreeAbsolute(to_checkout_path) catch {};

    const not_null_repo = repo orelse return error.MissingRepository;
    try checkoutRef(not_null_repo, from_ref_c, from_checkout_path, allocator);
    try checkoutRef(not_null_repo, to_ref_c, to_checkout_path, allocator);

    const from_gfile = c_libs.g_file_new_for_path(from_checkout_path.ptr);
    defer c_libs.g_object_unref(from_gfile);
    const to_gfile = c_libs.g_file_new_for_path(to_checkout_path.ptr);
    defer c_libs.g_object_unref(to_gfile);

    const modified_entries = c_libs.g_ptr_array_new();
    defer c_libs.g_ptr_array_unref(modified_entries);
    const removed_entries = c_libs.g_ptr_array_new();
    defer c_libs.g_ptr_array_unref(removed_entries);
    const added_entries = c_libs.g_ptr_array_new();
    defer c_libs.g_ptr_array_unref(added_entries);

    if (c_libs.ostree_diff_dirs(c_libs.OSTREE_DIFF_FLAGS_NONE, from_gfile, to_gfile, modified_entries, removed_entries, added_entries, null, &gerror) == 0) {
        if (gerror) |err| c_libs.g_error_free(err);
        return RollbackError.DiffFailed;
    }

    var diff_entries = std.ArrayList(DiffEntry).init(allocator);
    errdefer {
        for (diff_entries.items) |entry| allocator.free(entry.path);
        diff_entries.deinit();
    }

    var index: usize = 0;
    while (index < added_entries.*.len) : (index += 1) {
        const diff_item: *c_libs.OstreeDiffItem = @ptrCast(@alignCast(added_entries.*.pdata[index]));
        const file_path = std.mem.span(@as([*:0]u8, @ptrCast(c_libs.g_file_get_path(diff_item.target))));
        try diff_entries.append(.{ .path = try allocator.dupe(u8, file_path), .kind = .added });
    }

    index = 0;
    while (index < removed_entries.*.len) : (index += 1) {
        const diff_item: *c_libs.OstreeDiffItem = @ptrCast(@alignCast(removed_entries.*.pdata[index]));
        const file_path = std.mem.span(@as([*:0]u8, @ptrCast(c_libs.g_file_get_path(diff_item.src))));
        try diff_entries.append(.{ .path = try allocator.dupe(u8, file_path), .kind = .removed });
    }

    index = 0;
    while (index < modified_entries.*.len) : (index += 1) {
        const diff_item: *c_libs.OstreeDiffItem = @ptrCast(@alignCast(modified_entries.*.pdata[index]));
        const file_path = std.mem.span(@as([*:0]u8, @ptrCast(c_libs.g_file_get_path(diff_item.target))));
        try diff_entries.append(.{ .path = try allocator.dupe(u8, file_path), .kind = .modified });
    }

    return diff_entries.toOwnedSlice();
}

// ── Helpers functions ───────────────────────────────────────────────────────
// Resolves a commit hash string to a full checksum via ostree_repo_resolve_rev
fn resolveCommit(repo: *c_libs.OstreeRepo, commit_hash_c: [:0]const u8) ![*:0]u8 {
    var gerror: ?*c_libs.GError = null;
    var resolved: ?[*:0]u8 = null;

    if (c_libs.ostree_repo_resolve_rev(repo, commit_hash_c.ptr, 0, &resolved, &gerror) == 0) {
        if (gerror) |err| c_libs.g_error_free(err);
        return RollbackError.CommitNotFound;
    }

    return resolved orelse RollbackError.CommitNotFound;
}

// Creates a temporary directory adjacent to root_path (e.g. /usr → /usr-rollback-<timestamp>)
fn createStagingDir(root_path_c: [:0]const u8, allocator: std.mem.Allocator) ![:0]const u8 {
    const timestamp = std.time.milliTimestamp();
    const staging_path = try std.fmt.allocPrintZ(allocator, "{s}-rollback-{d}", .{ root_path_c, timestamp });
    errdefer allocator.free(staging_path);

    std.fs.makeDirAbsolute(staging_path) catch {
        return RollbackError.StagingFailed;
    };

    return staging_path;
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

    const result = std.os.linux.syscall5(
        .renameat2,
        @bitCast(@as(isize, AT_FDCWD)),
        @intFromPtr(staging_path.ptr),
        @bitCast(@as(isize, AT_FDCWD)),
        @intFromPtr(root_path_c.ptr),
        RENAME_EXCHANGE,
    );

    const errno_value = std.os.linux.E.init(result);
    if (errno_value != .SUCCESS) {
        return RollbackError.SwapFailed;
    }
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

// A low-level function for "deploying" a commit to a live system
fn checkoutRef(repo: *c_libs.OstreeRepo, ref_c: [:0]const u8, destination_path: [:0]const u8, allocator: std.mem.Allocator) !void {
    _ = allocator;

    var gerror: ?*c_libs.GError = null;

    var resolved_checksum: ?[*:0]u8 = null;
    defer if (resolved_checksum) |cs| c_libs.g_free(@ptrCast(cs));

    if (c_libs.ostree_repo_resolve_rev(repo, ref_c.ptr, 0, &resolved_checksum, &gerror) == 0) {
        if (gerror) |err| c_libs.g_error_free(err);
        return RollbackError.DiffFailed;
    }

    std.fs.makeDirAbsolute(destination_path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    var checkout_options = std.mem.zeroes(c_libs.OstreeRepoCheckoutAtOptions);
    checkout_options.mode = c_libs.OSTREE_REPO_CHECKOUT_MODE_NONE;
    checkout_options.overwrite_mode = c_libs.OSTREE_REPO_CHECKOUT_OVERWRITE_UNION_FILES;

    if (c_libs.ostree_repo_checkout_at(repo, &checkout_options, std.c.AT.FDCWD, destination_path.ptr, resolved_checksum, null, &gerror) == 0) {
        if (gerror) |err| c_libs.g_error_free(err);
        return RollbackError.DiffFailed;
    }
}
