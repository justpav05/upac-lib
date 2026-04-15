// ── Imports ─────────────────────────────────────────────────────────────────────
const std = @import("std");

const data = @import("upac-data");

const types = @import("upac-types");
const CommitEntry = types.CommitEntry;
const PackageDiffEntry = types.PackageDiffEntry;
const AttributedDiffEntry = types.AttributedDiffEntry;

const DiffEntry = types.DiffEntry;
const DiffKind = types.DiffKind;

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

    const staging_path = try resolveStagingDir(root_path_c, allocator);
    defer allocator.free(staging_path);
    errdefer std.fs.deleteTreeAbsolute(staging_path) catch {};

    const staging_root_path = try resolveStagingRootDir(root_path_c, allocator);
    defer allocator.free(staging_root_path);

    const staging_usr_path = try resolveStagingUsrDir(staging_path, allocator);
    defer allocator.free(staging_usr_path);

    try checkoutToStaging(repo.?, resolved_checksum, staging_path);

    try atomicSwap(staging_root_path, staging_usr_path);

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
pub fn diffFiles(repo_path: []const u8, from_ref: []const u8, to_ref: []const u8, root_path: []const u8, allocator: std.mem.Allocator) ![]DiffEntry {
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

    const root_path_c = try std.fmt.allocPrintZ(allocator, "{s}", .{root_path});
    defer allocator.free(root_path_c);

    const timestamp = std.time.milliTimestamp();

    const from_checkout_path = try std.fmt.allocPrintZ(allocator, "{s}/tmp/upac_diff_from_{d}", .{ root_path_c, timestamp });
    defer allocator.free(from_checkout_path);
    defer std.fs.deleteTreeAbsolute(from_checkout_path) catch {};

    const to_checkout_path = try std.fmt.allocPrintZ(allocator, "{s}/tmp/upac_diff_to_{d}", .{ root_path_c, timestamp + 1 });
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

    const to_prefix = @as([]const u8, to_checkout_path);
    const from_prefix = @as([]const u8, from_checkout_path);

    var index: usize = 0;
    while (index < added_entries.*.len) : (index += 1) {
        const gfile_ptr: *c_libs.GFile = @ptrCast(@alignCast(added_entries.*.pdata[index]));
        const raw_path = c_libs.g_file_get_path(gfile_ptr);
        defer c_libs.g_free(@ptrCast(raw_path));

        if (raw_path == null) continue;

        const file_path = std.mem.span(raw_path.?);
        const rel_path = if (std.mem.startsWith(u8, file_path, to_prefix)) file_path[to_prefix.len..] else file_path;
        try diff_entries.append(.{ .path = try allocator.dupe(u8, rel_path), .kind = .added });
    }

    index = 0;
    while (index < removed_entries.*.len) : (index += 1) {
        const gfile_ptr: *c_libs.GFile = @ptrCast(@alignCast(removed_entries.*.pdata[index]));
        const raw_path = c_libs.g_file_get_path(gfile_ptr);
        defer c_libs.g_free(@ptrCast(raw_path));

        if (raw_path == null) continue;

        const file_path = std.mem.span(raw_path.?);
        const rel_path = if (std.mem.startsWith(u8, file_path, from_prefix)) file_path[from_prefix.len..] else file_path;
        try diff_entries.append(.{ .path = try allocator.dupe(u8, rel_path), .kind = .removed });
    }

    index = 0;
    while (index < modified_entries.*.len) : (index += 1) {
        const diff_item: *c_libs.OstreeDiffItem = @ptrCast(@alignCast(modified_entries.*.pdata[index]));
        const raw_path = c_libs.g_file_get_path(diff_item.target);
        defer c_libs.g_free(@ptrCast(raw_path));

        if (raw_path == null) continue;

        const file_path = std.mem.span(raw_path.?);
        const rel_path = if (std.mem.startsWith(u8, file_path, to_prefix)) file_path[to_prefix.len..] else file_path;
        try diff_entries.append(.{ .path = try allocator.dupe(u8, rel_path), .kind = .modified });
    }

    return diff_entries.toOwnedSlice();
}

pub fn diffPackages(repo_path: []const u8, from_ref: []const u8, to_ref: []const u8, allocator: std.mem.Allocator) ![]PackageDiffEntry {
    const repo_path_c = try std.fmt.allocPrintZ(allocator, "{s}", .{repo_path});
    defer allocator.free(repo_path_c);

    const gfile = c_libs.g_file_new_for_path(repo_path_c.ptr);
    defer c_libs.g_object_unref(gfile);

    const repo = c_libs.ostree_repo_new(gfile);
    defer c_libs.g_object_unref(repo);

    var gerror: ?*c_libs.GError = null;
    if (c_libs.ostree_repo_open(repo, null, &gerror) == 0) {
        if (gerror) |err| c_libs.g_error_free(err);
        return RollbackError.RepoOpenFailed;
    }

    const from_commit_body = try getRefBody(repo.?, from_ref, allocator);
    defer if (from_commit_body) |body| allocator.free(body);

    const to_commit_body = try getRefBody(repo.?, to_ref, allocator);
    defer if (to_commit_body) |body| allocator.free(body);

    var from_commit_file_map = try parsePackageBody(from_commit_body orelse "", allocator);
    defer freeStringMap(&from_commit_file_map, allocator);

    var to_commit_file_map = try parsePackageBody(to_commit_body orelse "", allocator);
    defer freeStringMap(&to_commit_file_map, allocator);

    var entries = std.ArrayList(PackageDiffEntry).init(allocator);
    errdefer {
        for (entries.items) |package_diff_entry| allocator.free(package_diff_entry.name);
        entries.deinit();
    }

    var to_commit_file_map_iter = to_commit_file_map.iterator();
    while (to_commit_file_map_iter.next()) |entry| {
        if (from_commit_file_map.get(entry.key_ptr.*)) |from_commit_checksum| {
            if (!std.mem.eql(u8, from_commit_checksum, entry.value_ptr.*)) try entries.append(.{ .name = try allocator.dupe(u8, entry.key_ptr.*), .kind = .updated });
        } else try entries.append(.{ .name = try allocator.dupe(u8, entry.key_ptr.*), .kind = .added });
    }

    var from_commit_file_map_iter = from_commit_file_map.iterator();
    while (from_commit_file_map_iter.next()) |entry| {
        if (!to_commit_file_map.contains(entry.key_ptr.*)) try entries.append(.{ .name = try allocator.dupe(u8, entry.key_ptr.*), .kind = .removed });
    }

    return entries.toOwnedSlice();
}

pub fn diffFilesAttributed(repo_path: []const u8, from_ref: []const u8, to_ref: []const u8, root_path: []const u8, db_path: []const u8, allocator: std.mem.Allocator) ![]AttributedDiffEntry {
    const raw_files_diff = try diffFiles(repo_path, from_ref, to_ref, root_path, allocator);
    defer {
        for (raw_files_diff) |entry| allocator.free(entry.path);
        allocator.free(raw_files_diff);
    }

    var file_pkg = std.StringHashMap([]const u8).init(allocator);
    defer freeStringMap(&file_pkg, allocator);

    try buildFilePkgMap(repo_path, to_ref, db_path, &file_pkg, allocator);
    try buildFilePkgMap(repo_path, from_ref, db_path, &file_pkg, allocator);

    var result = std.ArrayList(AttributedDiffEntry).init(allocator);
    errdefer {
        for (result.items) |entry| {
            allocator.free(entry.path);
            allocator.free(entry.package_name);
        }
        result.deinit();
    }

    for (raw_files_diff) |entry| {
        const pkg = file_pkg.get(entry.path) orelse "";
        try result.append(.{
            .path = try allocator.dupe(u8, entry.path),
            .kind = entry.kind,
            .package_name = try allocator.dupe(u8, pkg),
        });
    }

    return result.toOwnedSlice();
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

// Resolve a temporary directory adjacent to root_path (e.g. /usr → /usr-rollback-<timestamp>)
fn resolveStagingDir(root_path_c: [:0]const u8, allocator: std.mem.Allocator) ![:0]const u8 {
    const timestamp = std.time.milliTimestamp();
    const staging_path_c = if (root_path_c[root_path_c.len - 1] == '/')
        try std.fmt.allocPrintZ(allocator, "{s}usr-rollback-{d}", .{ root_path_c[0 .. root_path_c.len - 1], timestamp })
    else
        try std.fmt.allocPrintZ(allocator, "{s}/usr-rollback-{d}", .{ root_path_c, timestamp });
    errdefer allocator.free(staging_path_c);

    return staging_path_c;
}

// Resolve a root dir (e.g. /usr → /usr-rollback-<timestamp>)
fn resolveStagingRootDir(root_path_c: [:0]const u8, allocator: std.mem.Allocator) ![:0]const u8 {
    const staging_root_path_c = if (root_path_c[root_path_c.len - 1] == '/')
        try std.fmt.allocPrintZ(allocator, "{s}usr", .{root_path_c[0 .. root_path_c.len - 1]})
    else
        try std.fmt.allocPrintZ(allocator, "{s}/usr", .{root_path_c});
    errdefer allocator.free(staging_root_path_c);

    return staging_root_path_c;
}

// Resolve a temp dir with usr dir (e.g. /usr → /usr-rollback-<timestamp>)
fn resolveStagingUsrDir(staging_path: []const u8, allocator: std.mem.Allocator) ![:0]const u8 {
    const staging_usr_path_c = try std.fmt.allocPrintZ(allocator, "{s}/usr", .{staging_path});
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
        error.FileNotFound => {
            // Parent directories don't exist — create the entire chain
            const path_slice: []const u8 = destination_path;
            // Strip leading '/' to make it relative, then use root dir as base
            const rel = if (path_slice.len > 0 and path_slice[0] == '/') path_slice[1..] else path_slice;
            var root = std.fs.openDirAbsolute("/", .{}) catch return error.FileNotFound;
            defer root.close();
            root.makePath(rel) catch return error.FileNotFound;
        },
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

fn getRefBody(repo: *c_libs.OstreeRepo, ostree_ref: []const u8, allocator: std.mem.Allocator) !?[]const u8 {
    const ostree_ref_c = try std.fmt.allocPrintZ(allocator, "{s}", .{ostree_ref});
    defer allocator.free(ostree_ref_c);

    var gerror: ?*c_libs.GError = null;
    var checksum: ?[*:0]u8 = null;
    if (c_libs.ostree_repo_resolve_rev(repo, ostree_ref_c.ptr, 1, &checksum, &gerror) == 0 or checksum == null) {
        if (gerror) |err| c_libs.g_error_free(err);
        return null;
    }
    defer c_libs.g_free(@ptrCast(checksum));

    var commit_variant: ?*c_libs.GVariant = null;
    if (c_libs.ostree_repo_load_variant(repo, c_libs.OSTREE_OBJECT_TYPE_COMMIT, checksum, &commit_variant, &gerror) == 0) {
        if (gerror) |err| c_libs.g_error_free(err);
        return null;
    }
    defer if (commit_variant) |variant| c_libs.g_variant_unref(variant);

    const body_variant = c_libs.g_variant_get_child_value(commit_variant, 4);
    defer if (body_variant) |variant| c_libs.g_variant_unref(variant);

    var commit_body_len: usize = 0;
    const commit_body_ptr = c_libs.g_variant_get_string(body_variant, &commit_body_len);
    return try allocator.dupe(u8, commit_body_ptr[0..commit_body_len]);
}

fn parsePackageBody(body: []const u8, allocator: std.mem.Allocator) !std.StringHashMap([]const u8) {
    var map = std.StringHashMap([]const u8).init(allocator);
    errdefer freeStringMap(&map, allocator);

    var line_iter = std.mem.splitScalar(u8, body, '\n');
    while (line_iter.next()) |line| {
        const trimmed_line = std.mem.trim(u8, line, " \t\r");
        if (trimmed_line.len == 0) continue;

        const separator_index = std.mem.indexOfScalar(u8, trimmed_line, ' ') orelse continue;

        const package_name = trimmed_line[0..separator_index];
        const package_checksum = std.mem.trim(u8, trimmed_line[separator_index + 1 ..], " \t");

        if (package_name.len == 0 or package_checksum.len == 0) continue;
        try map.put(try allocator.dupe(u8, package_name), try allocator.dupe(u8, package_checksum));
    }
    return map;
}

fn freeStringMap(map: *std.StringHashMap([]const u8), allocator: std.mem.Allocator) void {
    var map_iter = map.iterator();
    while (map_iter.next()) |entry| {
        allocator.free(entry.key_ptr.*);
        allocator.free(entry.value_ptr.*);
    }
    map.deinit();
}

fn buildFilePkgMap(repo_path: []const u8, ref: []const u8, db_path: []const u8, out: *std.StringHashMap([]const u8), allocator: std.mem.Allocator) !void {
    const repo_path_c = try std.fmt.allocPrintZ(allocator, "{s}", .{repo_path});
    defer allocator.free(repo_path_c);

    const gfile = c_libs.g_file_new_for_path(repo_path_c.ptr);
    defer c_libs.g_object_unref(gfile);

    const repo = c_libs.ostree_repo_new(gfile);
    defer c_libs.g_object_unref(repo);

    var gerror: ?*c_libs.GError = null;
    if (c_libs.ostree_repo_open(repo, null, &gerror) == 0) {
        if (gerror) |err| c_libs.g_error_free(err);
        return;
    }

    const body = (try getRefBody(repo.?, ref, allocator)) orelse return;
    defer allocator.free(body);

    var pkg_map = try parsePackageBody(body, allocator);
    defer freeStringMap(&pkg_map, allocator);

    var pkg_map_iter = pkg_map.iterator();
    while (pkg_map_iter.next()) |entry| {
        const pkg_name = entry.key_ptr.*;
        const pkg_checksum = entry.value_ptr.*;

        var file_map = data.readFiles(db_path, pkg_checksum, allocator) catch continue;
        defer data.freeFileMap(&file_map, allocator);

        var file_map_iter = file_map.iterator();
        while (file_map_iter.next()) |file_map_entry| {
            if (!out.contains(file_map_entry.key_ptr.*)) {
                try out.put(
                    try allocator.dupe(u8, file_map_entry.key_ptr.*),
                    try allocator.dupe(u8, pkg_name),
                );
            }
        }
    }
}
