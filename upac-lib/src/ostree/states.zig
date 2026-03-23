const std = @import("std");

const database = @import("upac-database");

const ostree = @import("ostree.zig");
const OstreeError = ostree.OstreeError;
const CommitMachine = ostree.CommitMachine;
const StateId = ostree.StateId;

pub const c_libs = ostree.c_libs;

// ── Состояния FSM ─────────────────────────────────────────────────────────────
pub fn stateOpeningRepo(machine: *CommitMachine) anyerror!void {
    try machine.enter(.opening_repo);

    const repo_path_c = try std.fmt.allocPrintZ(machine.allocator, "{s}", .{machine.request.repo_path});
    defer machine.allocator.free(repo_path_c);

    const g_file = c_libs.g_file_new_for_path(repo_path_c.ptr);
    defer c_libs.g_object_unref(g_file);

    var global_glib_err: ?*c_libs.GError = null;
    const ostree_repo_c = c_libs.ostree_repo_new(g_file);

    if (c_libs.ostree_repo_open(ostree_repo_c, null, &global_glib_err) == 0) {
        if (global_glib_err) |err| c_libs.g_error_free(err);
        c_libs.g_object_unref(ostree_repo_c);
        if (machine.exhausted()) {
            stateFailed(machine);
            return OstreeError.RepoOpenFailed;
        }
        machine.retries += 1;
        return stateOpeningRepo(machine);
    }

    machine.repo = ostree_repo_c;
    machine.retries = 0;
    return stateBuildingMessage(machine);
}

fn stateBuildingMessage(machine: *CommitMachine) anyerror!void {
    try machine.enter(.building_message);

    var subject_buf = std.ArrayList(u8).init(machine.allocator);
    errdefer subject_buf.deinit();
    const subject_writer = subject_buf.writer();

    try subject_writer.writeAll(machine.request.operation.toString());
    try subject_writer.writeAll(": ");
    for (machine.request.packages, 0..) |package, index| {
        if (index > 0) try subject_writer.writeAll(", ");
        try subject_writer.print("{s} {s}", .{ package.name, package.version });
    }
    machine.subject = try subject_buf.toOwnedSlice();

    var body_buf = std.ArrayList(u8).init(machine.allocator);
    errdefer body_buf.deinit();
    const body_writer = body_buf.writer();

    try body_writer.writeAll("Installed packages:\n");

    const package_names = database.listPackages(machine.request.database_path, machine.allocator) catch |err| {
        stateFailed(machine);
        return err;
    };
    defer {
        for (package_names) |name| machine.allocator.free(name);
        machine.allocator.free(package_names);
    }

    for (package_names) |package_name| {
        const package_meta = database.getMeta(machine.request.database_path, package_name, machine.allocator) catch continue;
        defer {
            machine.allocator.free(package_meta.name);
            machine.allocator.free(package_meta.version);
            machine.allocator.free(package_meta.author);
            machine.allocator.free(package_meta.description);
            machine.allocator.free(package_meta.license);
            machine.allocator.free(package_meta.url);
            machine.allocator.free(package_meta.checksum);
        }

        try body_writer.print("pkg name={s} version={s} author={s} description={s} license={s} url={s} installed_at={d} checksum={s}\n", .{
            package_meta.name,
            package_meta.version,
            package_meta.author,
            package_meta.description,
            package_meta.license,
            package_meta.url,
            package_meta.installed_at,
            package_meta.checksum,
        });
    }

    machine.body = try body_buf.toOwnedSlice();
    machine.retries = 0;
    return stateCommitting(machine);
}

fn stateCommitting(machine: *CommitMachine) anyerror!void {
    try machine.enter(.committing);

    const c_ostree_repo = machine.repo orelse {
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

    const content_file = c_libs.g_file_new_for_path(content_path_c.ptr);
    defer c_libs.g_object_unref(content_file);

    var global_glib_err: ?*c_libs.GError = null;
    var commit_checksum: [*c]u8 = null;
    defer if (commit_checksum) |checksu| c_libs.g_free(checksu);

    if (c_libs.ostree_repo_prepare_transaction(c_ostree_repo, null, null, &global_glib_err) == 0) {
        if (global_glib_err) |err| c_libs.g_error_free(err);
        if (machine.exhausted()) {
            stateFailed(machine);
            return OstreeError.CommitFailed;
        }
        machine.retries += 1;
        return stateCommitting(machine);
    }

    const mtree: ?*c_libs.OstreeMutableTree = c_libs.ostree_mutable_tree_new();
    defer if (mtree) |t| c_libs.g_object_unref(t);

    if (c_libs.ostree_repo_write_directory_to_mtree(c_ostree_repo, content_file, mtree, null, null, &global_glib_err) == 0) {
        if (global_glib_err) |err| c_libs.g_error_free(err);
        _ = c_libs.ostree_repo_abort_transaction(c_ostree_repo, null, null);
        if (machine.exhausted()) {
            stateFailed(machine);
            return OstreeError.CommitFailed;
        }
        machine.retries += 1;
        return stateCommitting(machine);
    }

    var root: ?*c_libs.GFile = null;
    defer if (root) |r| c_libs.g_object_unref(r);

    if (c_libs.ostree_repo_write_mtree(c_ostree_repo, mtree, &root, null, &global_glib_err) == 0) {
        if (global_glib_err) |err| c_libs.g_error_free(err);
        _ = c_libs.ostree_repo_abort_transaction(c_ostree_repo, null, null);
        if (machine.exhausted()) {
            stateFailed(machine);
            return OstreeError.CommitFailed;
        }
        machine.retries += 1;
        return stateCommitting(machine);
    }

    var parent_checksum: [*c]u8 = null;
    defer if (parent_checksum) |checksum| c_libs.g_free(checksum);

    _ = c_libs.ostree_repo_resolve_rev(
        c_ostree_repo,
        branch_c.ptr,
        1,
        &parent_checksum,
        null,
    );

    if (c_libs.ostree_repo_write_commit(
        c_ostree_repo,
        parent_checksum,
        subject_c.ptr,
        body_c.ptr,
        null,
        @ptrCast(root),
        &commit_checksum,
        null,
        &global_glib_err,
    ) == 0) {
        if (global_glib_err) |err| c_libs.g_error_free(err);
        _ = c_libs.ostree_repo_abort_transaction(c_ostree_repo, null, null);
        if (machine.exhausted()) {
            stateFailed(machine);
            return OstreeError.CommitFailed;
        }
        machine.retries += 1;
        return stateCommitting(machine);
    }

    c_libs.ostree_repo_transaction_set_ref(c_ostree_repo, null, branch_c.ptr, commit_checksum);

    if (c_libs.ostree_repo_commit_transaction(c_ostree_repo, null, null, &global_glib_err) == 0) {
        if (global_glib_err) |err| c_libs.g_error_free(err);
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
}

fn stateFailed(machine: *CommitMachine) void {
    _ = machine.enter(.failed) catch {};
    std.debug.print("✗ ostree failed, path: ", .{});
    for (machine.stack.items) |state_id| std.debug.print("{s} ", .{@tagName(state_id)});
    std.debug.print("\n", .{});
}
