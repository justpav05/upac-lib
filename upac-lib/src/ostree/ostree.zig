const std = @import("std");

const states = @import("states.zig");

const fsm = @import("machine.zig");
const StateId = fsm.StateId;
const CommitMachine = fsm.CommitMachine;

const db = @import("upac-database");
const PackageMeta = db.PackageMeta;

const c_libs = @cImport({
    @cInclude("ostree.h");
    @cInclude("glib.h");
    @cInclude("gio/gio.h");
    @cInclude("fcntl.h");
});

// ── Публичные типы ────────────────────────────────────────────────────────────
pub const OstreeCommitRequest = struct {
    repo_path: []const u8,
    content_path: []const u8,
    branch: []const u8,
    operation: []const u8,
    packages: []const PackageMeta,
    database_path: []const u8,
};

pub const DiffEntry = struct {
    path: []const u8,
    kind: DiffKind,
};

pub const DiffKind = enum { added, removed, modified };

pub const OstreeError = error{
    RepoOpenFailed,
    CommitFailed,
    DiffFailed,
    RollbackFailed,
    NoPreviousCommit,
    Unexpected,
};

// ── Публичное API ─────────────────────────────────────────────────────────────
pub fn commit(request: OstreeCommitRequest, allocator: std.mem.Allocator) !void {
    var machine = CommitMachine{
        .request = request,
        .stack = std.ArrayList(StateId).init(allocator),
        .retries = 0,
        .max_retries = 2,
        .allocator = allocator,
        .repo = null,
        .subject = null,
        .body = null,
    };
    defer machine.deinit();

    try states.stateOpeningRepo(&machine);
}

// ── Вспомогательная: checkout коммита во временную директорию ─────────────────
fn checkoutRef(c_ostree_repo: *c_libs.OstreeRepo, ref: [:0]const u8, destination_path: [:0]const u8) !void {
    var global_struct_glib_err: ?*c_libs.GError = null;

    var commit_checksum: [*c]u8 = null;
    defer if (commit_checksum) |checksum| c_libs.g_free(checksum);

    if (c_libs.ostree_repo_resolve_rev(c_ostree_repo, ref.ptr, 0, &commit_checksum, &global_struct_glib_err) == 0) {
        if (global_struct_glib_err) |struct_glib_err| c_libs.g_error_free(struct_glib_err);
        return OstreeError.DiffFailed;
    }

    std.fs.makeDirAbsolute(destination_path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    var options = std.mem.zeroes(c_libs.OstreeRepoCheckoutAtOptions);
    options.mode = c_libs.OSTREE_REPO_CHECKOUT_MODE_NONE;
    options.overwrite_mode = c_libs.OSTREE_REPO_CHECKOUT_OVERWRITE_UNION_FILES;

    if (c_libs.ostree_repo_checkout_at(
        c_ostree_repo,
        &options,
        std.c.AT.FDCWD,
        destination_path.ptr,
        commit_checksum,
        null,
        &global_struct_glib_err,
    ) == 0) {
        if (global_struct_glib_err) |struct_glib_err| c_libs.g_error_free(struct_glib_err);
        return OstreeError.DiffFailed;
    }
}

// ── Прямые операции (без FSM) ─────────────────────────────────────────────────
pub fn diff(repo_path: []const u8, from_ref: []const u8, to_ref: []const u8, allocator: std.mem.Allocator) ![]DiffEntry {
    const repo_path_c = try std.fmt.allocPrintZ(allocator, "{s}", .{repo_path});
    defer allocator.free(repo_path_c);

    const g_repo_file = c_libs.g_file_new_for_path(repo_path_c.ptr);
    defer c_libs.g_object_unref(g_repo_file);

    var global_struct_glib_err: ?*c_libs.GError = null;
    const c_ostree_repo = c_libs.ostree_repo_new(g_repo_file);
    defer c_libs.g_object_unref(c_ostree_repo);

    if (c_libs.ostree_repo_open(c_ostree_repo, null, &global_struct_glib_err) == 0) {
        if (global_struct_glib_err) |struct_glib_err| c_libs.g_error_free(struct_glib_err);
        return OstreeError.RepoOpenFailed;
    }

    // Временные директории для checkout
    const timestamp = std.time.milliTimestamp();

    const from_checkout_path = try std.fmt.allocPrintZ(allocator, "/tmp/upac_diff_from_{d}", .{timestamp});
    defer allocator.free(from_checkout_path);
    defer std.fs.deleteTreeAbsolute(from_checkout_path) catch {};

    const to_checkout_path = try std.fmt.allocPrintZ(allocator, "/tmp/upac_diff_to_{d}", .{timestamp + 1});
    defer allocator.free(to_checkout_path);
    defer std.fs.deleteTreeAbsolute(to_checkout_path) catch {};

    const from_ref_c = try std.fmt.allocPrintZ(allocator, "{s}", .{from_ref});
    defer allocator.free(from_ref_c);
    const to_ref_c = try std.fmt.allocPrintZ(allocator, "{s}", .{to_ref});
    defer allocator.free(to_ref_c);

    try checkoutRef(c_ostree_repo.?, from_ref_c, from_checkout_path);
    try checkoutRef(c_ostree_repo.?, to_ref_c, to_checkout_path);

    const from_checkout_file = c_libs.g_file_new_for_path(from_checkout_path.ptr);
    defer c_libs.g_object_unref(from_checkout_file);
    const to_checkout_file = c_libs.g_file_new_for_path(to_checkout_path.ptr);
    defer c_libs.g_object_unref(to_checkout_file);

    const modified_entries = c_libs.g_ptr_array_new();
    const removed_entries = c_libs.g_ptr_array_new();
    const added_entries = c_libs.g_ptr_array_new();
    defer c_libs.g_ptr_array_unref(modified_entries);
    defer c_libs.g_ptr_array_unref(removed_entries);
    defer c_libs.g_ptr_array_unref(added_entries);

    if (c_libs.ostree_diff_dirs(
        c_libs.OSTREE_DIFF_FLAGS_NONE,
        from_checkout_file,
        to_checkout_file,
        modified_entries,
        removed_entries,
        added_entries,
        null,
        &global_struct_glib_err,
    ) == 0) {
        if (global_struct_glib_err) |struct_glib_err| c_libs.g_error_free(struct_glib_err);
        return OstreeError.DiffFailed;
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

pub fn rollback(repo_path: []const u8, content_path: []const u8, branch: []const u8, allocator: std.mem.Allocator) !void {
    const repo_path_c = try std.fmt.allocPrintZ(allocator, "{s}", .{repo_path});
    defer allocator.free(repo_path_c);

    const content_path_c = try std.fmt.allocPrintZ(allocator, "{s}", .{content_path});
    defer allocator.free(content_path_c);

    const branch_c = try std.fmt.allocPrintZ(allocator, "{s}", .{branch});
    defer allocator.free(branch_c);

    const g_repo_file = c_libs.g_file_new_for_path(repo_path_c.ptr);
    defer c_libs.g_object_unref(g_repo_file);

    var global_struct_glib_err: ?*c_libs.GError = null;
    const struct_ostree_repo = c_libs.ostree_repo_new(g_repo_file);
    defer c_libs.g_object_unref(struct_ostree_repo);

    if (c_libs.ostree_repo_open(struct_ostree_repo, null, &global_struct_glib_err) == 0) {
        if (global_struct_glib_err) |struct_glib_err| c_libs.g_error_free(struct_glib_err);
        return OstreeError.RepoOpenFailed;
    }

    var current_checksum: [*c]u8 = null;
    defer if (current_checksum) |checksum| c_libs.g_free(checksum);

    if (c_libs.ostree_repo_resolve_rev(struct_ostree_repo, branch_c.ptr, 0, &current_checksum, &global_struct_glib_err) == 0) {
        if (global_struct_glib_err) |struct_glib_err| c_libs.g_error_free(struct_glib_err);
        return OstreeError.NoPreviousCommit;
    }

    var commit_variant: ?*c_libs.GVariant = null;
    defer if (commit_variant) |v| c_libs.g_variant_unref(v);

    if (c_libs.ostree_repo_load_variant(
        struct_ostree_repo,
        c_libs.OSTREE_OBJECT_TYPE_COMMIT,
        current_checksum,
        &commit_variant,
        &global_struct_glib_err,
    ) == 0) {
        if (global_struct_glib_err) |struct_glib_err| c_libs.g_error_free(struct_glib_err);
        return OstreeError.RollbackFailed;
    }

    const parent_checksum = c_libs.ostree_commit_get_parent(commit_variant);
    if (parent_checksum == null) return OstreeError.NoPreviousCommit;

    var options = std.mem.zeroes(c_libs.OstreeRepoCheckoutAtOptions);
    options.mode = c_libs.OSTREE_REPO_CHECKOUT_MODE_NONE;
    options.overwrite_mode = c_libs.OSTREE_REPO_CHECKOUT_OVERWRITE_UNION_FILES;

    if (c_libs.ostree_repo_checkout_at(
        struct_ostree_repo,
        &options,
        std.c.AT.FDCWD,
        content_path_c.ptr,
        parent_checksum,
        null,
        &global_struct_glib_err,
    ) == 0) {
        if (global_struct_glib_err) |struct_glib_err| c_libs.g_error_free(struct_glib_err);
        return OstreeError.RollbackFailed;
    }

    if (c_libs.ostree_repo_prepare_transaction(struct_ostree_repo, null, null, &global_struct_glib_err) == 0) {
        if (global_struct_glib_err) |struct_glib_err| c_libs.g_error_free(struct_glib_err);
        return OstreeError.RollbackFailed;
    }

    c_libs.ostree_repo_transaction_set_ref(struct_ostree_repo, null, branch_c.ptr, parent_checksum);

    if (c_libs.ostree_repo_commit_transaction(struct_ostree_repo, null, null, &global_struct_glib_err) == 0) {
        if (global_struct_glib_err) |struct_glib_err| c_libs.g_error_free(struct_glib_err);
        _ = c_libs.ostree_repo_abort_transaction(struct_ostree_repo, null, null);
        return OstreeError.RollbackFailed;
    }

    std.debug.print("✓ ostree rollback to {s}\n", .{std.mem.span(@as([*:0]u8, @ptrCast(parent_checksum)))});
}
