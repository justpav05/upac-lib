const std = @import("std");

const database = @import("upac-database");

const ostree = @import("ostree.zig");
const OstreeError = ostree.OstreeError;

const fsm = @import("machine.zig");
const CommitMachine = fsm.CommitMachine;

const c_librarys = @cImport({
    @cInclude("ostree.h");
    @cInclude("glib.h");
    @cInclude("gio/gio.h");
});

// ── Состояния FSM ─────────────────────────────────────────────────────────────
pub fn stateOpeningRepo(machine: *CommitMachine) anyerror!void {
    try machine.enter(.opening_repo);

    const path_c = try std.fmt.allocPrintZ(machine.allocator, "{s}", .{machine.request.repo_path});
    defer machine.allocator.free(path_c);

    const file = c_librarys.g_file_new_for_path(path_c.ptr);
    defer c_librarys.g_object_unref(file);

    var err: ?*c_librarys.GError = null;
    const repo = c_librarys.ostree_repo_new(file);

    if (c_librarys.ostree_repo_open(repo, null, &err) == 0) {
        if (err) |e| c_librarys.g_error_free(e);
        c_librarys.g_object_unref(repo);
        if (machine.exhausted()) {
            stateFailed(machine);
            return OstreeError.RepoOpenFailed;
        }
        machine.retries += 1;
        return stateOpeningRepo(machine);
    }

    machine.repo = repo;
    machine.retries = 0;
    return stateBuildingMessage(machine);
}

fn stateBuildingMessage(machine: *CommitMachine) anyerror!void {
    try machine.enter(.building_message);

    var subject_buf = std.ArrayList(u8).init(machine.allocator);
    errdefer subject_buf.deinit();
    const sw = subject_buf.writer();

    try sw.writeAll(machine.request.operation);
    try sw.writeAll(": ");
    for (machine.request.packages, 0..) |pkg, i| {
        if (i > 0) try sw.writeAll(", ");
        try sw.print("{s} {s}", .{ pkg.name, pkg.version });
    }
    machine.subject = try subject_buf.toOwnedSlice();

    var body_buf = std.ArrayList(u8).init(machine.allocator);
    errdefer body_buf.deinit();
    const bw = body_buf.writer();

    try bw.writeAll("Installed packages:\n");

    const names = database.listPackages(machine.request.database_path, machine.allocator) catch |err| {
        stateFailed(machine);
        return err;
    };
    defer {
        for (names) |n| machine.allocator.free(n);
        machine.allocator.free(names);
    }

    for (names) |name| {
        const meta = database.getMeta(machine.request.database_path, name, machine.allocator) catch continue;
        defer {
            machine.allocator.free(meta.name);
            machine.allocator.free(meta.version);
            machine.allocator.free(meta.author);
            machine.allocator.free(meta.description);
            machine.allocator.free(meta.license);
            machine.allocator.free(meta.url);
            machine.allocator.free(meta.checksum);
        }
        try bw.print("  - {s} {s} ({s})\n", .{ meta.name, meta.version, meta.license });
    }

    machine.body = try body_buf.toOwnedSlice();
    machine.retries = 0;
    return stateCommitting(machine);
}

fn stateCommitting(machine: *CommitMachine) anyerror!void {
    try machine.enter(.committing);

    const repo = machine.repo orelse {
        stateFailed(machine);
        return OstreeError.RepoOpenFailed;
    };

    const content_path_c = try std.fmt.allocPrintZ(machine.allocator, "{s}", .{machine.request.content_path});
    defer machine.allocator.free(content_path_c);
    const branch_c = try std.fmt.allocPrintZ(machine.allocator, "{s}", .{machine.request.branch});
    defer machine.allocator.free(branch_c);
    const subject_c = try std.fmt.allocPrintZ(machine.allocator, "{s}", .{machine.subject.?});
    defer machine.allocator.free(subject_c);
    const body_c = try std.fmt.allocPrintZ(machine.allocator, "{s}", .{machine.body.?});
    defer machine.allocator.free(body_c);

    const content_file = c_librarys.g_file_new_for_path(content_path_c.ptr);
    defer c_librarys.g_object_unref(content_file);

    var err: ?*c_librarys.GError = null;
    var commit_checksum: [*c]u8 = null;
    defer if (commit_checksum) |cs| c_librarys.g_free(cs);

    if (c_librarys.ostree_repo_prepare_transaction(repo, null, null, &err) == 0) {
        if (err) |e| c_librarys.g_error_free(e);
        if (machine.exhausted()) {
            stateFailed(machine);
            return OstreeError.CommitFailed;
        }
        machine.retries += 1;
        return stateCommitting(machine);
    }

    const mtree: ?*c_librarys.OstreeMutableTree = c_librarys.ostree_mutable_tree_new();
    defer if (mtree) |t| c_librarys.g_object_unref(t);

    if (c_librarys.ostree_repo_write_directory_to_mtree(repo, content_file, mtree, null, null, &err) == 0) {
        if (err) |e| c_librarys.g_error_free(e);
        _ = c_librarys.ostree_repo_abort_transaction(repo, null, null);
        if (machine.exhausted()) {
            stateFailed(machine);
            return OstreeError.CommitFailed;
        }
        machine.retries += 1;
        return stateCommitting(machine);
    }

    var root: ?*c_librarys.GFile = null;
    defer if (root) |r| c_librarys.g_object_unref(r);

    if (c_librarys.ostree_repo_write_mtree(repo, mtree, &root, null, &err) == 0) {
        if (err) |e| c_librarys.g_error_free(e);
        _ = c_librarys.ostree_repo_abort_transaction(repo, null, null);
        if (machine.exhausted()) {
            stateFailed(machine);
            return OstreeError.CommitFailed;
        }
        machine.retries += 1;
        return stateCommitting(machine);
    }

    if (c_librarys.ostree_repo_write_commit(
        repo,
        null,
        subject_c.ptr,
        body_c.ptr,
        null,
        @ptrCast(root),
        &commit_checksum,
        null,
        &err,
    ) == 0) {
        if (err) |e| c_librarys.g_error_free(e);
        _ = c_librarys.ostree_repo_abort_transaction(repo, null, null);
        if (machine.exhausted()) {
            stateFailed(machine);
            return OstreeError.CommitFailed;
        }
        machine.retries += 1;
        return stateCommitting(machine);
    }

    c_librarys.ostree_repo_transaction_set_ref(repo, null, branch_c.ptr, commit_checksum);

    if (c_librarys.ostree_repo_commit_transaction(repo, null, null, &err) == 0) {
        if (err) |e| c_librarys.g_error_free(e);
        if (machine.exhausted()) {
            stateFailed(machine);
            return OstreeError.CommitFailed;
        }
        machine.retries += 1;
        return stateCommitting(machine);
    }

    machine.retries = 0;
    return stateDone(machine);
}

fn stateDone(machine: *CommitMachine) anyerror!void {
    try machine.enter(.done);
    std.debug.print("✓ ostree commit on branch '{s}'\n", .{machine.request.branch});
}

fn stateFailed(machine: *CommitMachine) void {
    _ = machine.enter(.failed) catch {};
    std.debug.print("✗ ostree failed, path: ", .{});
    for (machine.stack.items) |s| std.debug.print("{s} ", .{@tagName(s)});
    std.debug.print("\n", .{});
}
