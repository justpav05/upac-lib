const std = @import("std");

const states = @import("states.zig");

const fsm = @import("machine.zig");
const StateId = fsm.StateId;
const CommitMachine = fsm.CommitMachine;

const types = @import("types.zig");
const DiffEntry = types.DiffEntry;
const OstreeError = types.OstreeError;
pub const OstreeCommitRequest = types.OstreeCommitRequest;

const c_librarys = @cImport({
    @cInclude("ostree.h");
    @cInclude("glib.h");
    @cInclude("gio/gio.h");
    @cInclude("fcntl.h");
});

// ── Публичное API ─────────────────────────────────────────────────────────────

pub fn commit(request: OstreeCommitRequest, allocator: std.mem.Allocator) !void {
    var machine = CommitMachine{
        .request = request,
        .stack = std.ArrayList(StateId).init(allocator),
        .retries = 0,
        .max_retries = 3,
        .allocator = allocator,
        .repo = null,
        .subject = null,
        .body = null,
    };
    defer machine.deinit();

    try states.stateOpeningRepo(&machine);
}

// ── Вспомогательная: checkout коммита во временную директорию ─────────────────

fn checkoutRef(
    repo: *c_librarys.OstreeRepo,
    ref: [:0]const u8,
    out_path: [:0]const u8,
) !void {
    var err: ?*c_librarys.GError = null;

    var checksum: [*c]u8 = null;
    defer if (checksum) |cs| c_librarys.g_free(cs);

    if (c_librarys.ostree_repo_resolve_rev(repo, ref.ptr, 0, &checksum, &err) == 0) {
        if (err) |e| c_librarys.g_error_free(e);
        return OstreeError.DiffFailed;
    }

    std.fs.makeDirAbsolute(out_path) catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => return e,
    };

    var options = std.mem.zeroes(c_librarys.OstreeRepoCheckoutAtOptions);
    options.mode = c_librarys.OSTREE_REPO_CHECKOUT_MODE_NONE;
    options.overwrite_mode = c_librarys.OSTREE_REPO_CHECKOUT_OVERWRITE_UNION_FILES;

    if (c_librarys.ostree_repo_checkout_at(
        repo,
        &options,
        std.c.AT.FDCWD,
        out_path.ptr,
        checksum,
        null,
        &err,
    ) == 0) {
        if (err) |e| c_librarys.g_error_free(e);
        return OstreeError.DiffFailed;
    }
}

// ── Прямые операции (без FSM) ─────────────────────────────────────────────────

pub fn diff(
    repo_path: []const u8,
    from_ref: []const u8,
    to_ref: []const u8,
    allocator: std.mem.Allocator,
) ![]DiffEntry {
    const repo_path_c = try std.fmt.allocPrintZ(allocator, "{s}", .{repo_path});
    defer allocator.free(repo_path_c);

    const repo_file = c_librarys.g_file_new_for_path(repo_path_c.ptr);
    defer c_librarys.g_object_unref(repo_file);

    var err: ?*c_librarys.GError = null;
    const repo = c_librarys.ostree_repo_new(repo_file);
    defer c_librarys.g_object_unref(repo);

    if (c_librarys.ostree_repo_open(repo, null, &err) == 0) {
        if (err) |e| c_librarys.g_error_free(e);
        return OstreeError.RepoOpenFailed;
    }

    // Временные директории для checkout
    const ts = std.time.milliTimestamp();
    const tmp_a = try std.fmt.allocPrintZ(allocator, "/tmp/upac_diff_a_{d}", .{ts});
    defer allocator.free(tmp_a);
    const tmp_b = try std.fmt.allocPrintZ(allocator, "/tmp/upac_diff_b_{d}", .{ts + 1});
    defer allocator.free(tmp_b);
    defer std.fs.deleteTreeAbsolute(tmp_a) catch {};
    defer std.fs.deleteTreeAbsolute(tmp_b) catch {};

    const from_c = try std.fmt.allocPrintZ(allocator, "{s}", .{from_ref});
    defer allocator.free(from_c);
    const to_c = try std.fmt.allocPrintZ(allocator, "{s}", .{to_ref});
    defer allocator.free(to_c);

    try checkoutRef(repo.?, from_c, tmp_a);
    try checkoutRef(repo.?, to_c, tmp_b);

    const dir_a = c_librarys.g_file_new_for_path(tmp_a.ptr);
    defer c_librarys.g_object_unref(dir_a);
    const dir_b = c_librarys.g_file_new_for_path(tmp_b.ptr);
    defer c_librarys.g_object_unref(dir_b);

    const modified = c_librarys.g_ptr_array_new();
    const removed = c_librarys.g_ptr_array_new();
    const added = c_librarys.g_ptr_array_new();
    defer c_librarys.g_ptr_array_unref(modified);
    defer c_librarys.g_ptr_array_unref(removed);
    defer c_librarys.g_ptr_array_unref(added);

    if (c_librarys.ostree_diff_dirs(
        c_librarys.OSTREE_DIFF_FLAGS_NONE,
        dir_a,
        dir_b,
        modified,
        removed,
        added,
        null,
        &err,
    ) == 0) {
        if (err) |e| c_librarys.g_error_free(e);
        return OstreeError.DiffFailed;
    }

    var entries = std.ArrayList(DiffEntry).init(allocator);
    errdefer {
        for (entries.items) |e| allocator.free(e.path);
        entries.deinit();
    }

    var i: usize = 0;
    while (i < added.*.len) : (i += 1) {
        const item: *c_librarys.OstreeDiffItem = @ptrCast(@alignCast(added.*.pdata[i]));
        const path = std.mem.span(@as([*:0]u8, @ptrCast(c_librarys.g_file_get_path(item.target))));
        try entries.append(.{ .path = try allocator.dupe(u8, path), .kind = .added });
    }

    i = 0;
    while (i < removed.*.len) : (i += 1) {
        const item: *c_librarys.OstreeDiffItem = @ptrCast(@alignCast(removed.*.pdata[i]));
        const path = std.mem.span(@as([*:0]u8, @ptrCast(c_librarys.g_file_get_path(item.src))));
        try entries.append(.{ .path = try allocator.dupe(u8, path), .kind = .removed });
    }

    i = 0;
    while (i < modified.*.len) : (i += 1) {
        const item: *c_librarys.OstreeDiffItem = @ptrCast(@alignCast(modified.*.pdata[i]));
        const path = std.mem.span(@as([*:0]u8, @ptrCast(c_librarys.g_file_get_path(item.target))));
        try entries.append(.{ .path = try allocator.dupe(u8, path), .kind = .modified });
    }

    return entries.toOwnedSlice();
}

pub fn rollback(
    repo_path: []const u8,
    content_path: []const u8,
    branch: []const u8,
    allocator: std.mem.Allocator,
) !void {
    const repo_path_c = try std.fmt.allocPrintZ(allocator, "{s}", .{repo_path});
    defer allocator.free(repo_path_c);
    const content_path_c = try std.fmt.allocPrintZ(allocator, "{s}", .{content_path});
    defer allocator.free(content_path_c);
    const branch_c = try std.fmt.allocPrintZ(allocator, "{s}", .{branch});
    defer allocator.free(branch_c);

    const file = c_librarys.g_file_new_for_path(repo_path_c.ptr);
    defer c_librarys.g_object_unref(file);

    var err: ?*c_librarys.GError = null;
    const repo = c_librarys.ostree_repo_new(file);
    defer c_librarys.g_object_unref(repo);

    if (c_librarys.ostree_repo_open(repo, null, &err) == 0) {
        if (err) |e| c_librarys.g_error_free(e);
        return OstreeError.RepoOpenFailed;
    }

    var current_checksum: [*c]u8 = null;
    defer if (current_checksum) |cs| c_librarys.g_free(cs);

    if (c_librarys.ostree_repo_resolve_rev(repo, branch_c.ptr, 0, &current_checksum, &err) == 0) {
        if (err) |e| c_librarys.g_error_free(e);
        return OstreeError.NoPreviousCommit;
    }

    var commit_variant: ?*c_librarys.GVariant = null;
    defer if (commit_variant) |v| c_librarys.g_variant_unref(v);

    if (c_librarys.ostree_repo_load_variant(
        repo,
        c_librarys.OSTREE_OBJECT_TYPE_COMMIT,
        current_checksum,
        &commit_variant,
        &err,
    ) == 0) {
        if (err) |e| c_librarys.g_error_free(e);
        return OstreeError.RollbackFailed;
    }

    const parent_checksum = c_librarys.ostree_commit_get_parent(commit_variant);
    if (parent_checksum == null) return OstreeError.NoPreviousCommit;

    var options = std.mem.zeroes(c_librarys.OstreeRepoCheckoutAtOptions);
    options.mode = c_librarys.OSTREE_REPO_CHECKOUT_MODE_NONE;
    options.overwrite_mode = c_librarys.OSTREE_REPO_CHECKOUT_OVERWRITE_UNION_FILES;

    if (c_librarys.ostree_repo_checkout_at(
        repo,
        &options,
        std.c.AT.FDCWD,
        content_path_c.ptr,
        parent_checksum,
        null,
        &err,
    ) == 0) {
        if (err) |e| c_librarys.g_error_free(e);
        return OstreeError.RollbackFailed;
    }

    if (c_librarys.ostree_repo_prepare_transaction(repo, null, null, &err) == 0) {
        if (err) |e| c_librarys.g_error_free(e);
        return OstreeError.RollbackFailed;
    }

    c_librarys.ostree_repo_transaction_set_ref(repo, null, branch_c.ptr, parent_checksum);

    if (c_librarys.ostree_repo_commit_transaction(repo, null, null, &err) == 0) {
        if (err) |e| c_librarys.g_error_free(e);
        _ = c_librarys.ostree_repo_abort_transaction(repo, null, null);
        return OstreeError.RollbackFailed;
    }

    std.debug.print("✓ ostree rollback to {s}\n", .{std.mem.span(@as([*:0]u8, @ptrCast(parent_checksum)))});
}
