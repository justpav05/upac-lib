// ── Imports ─────────────────────────────────────────────────────────────────────
const diff = @import("diff.zig");
const std = diff.std;
const c_libs = diff.c_libs;
const data = diff.data;

const CSlice = diff.ffi.CSlice;
const CPackageMeta = diff.ffi.CPackageMeta;
const CPackageMetaArray = diff.ffi.CPackageMetaArray;

const CPackageDiffArray = diff.ffi.CPackageDiffArray;
const CPackageDiffEntry = diff.ffi.CPackageDiffEntry;

const CAttributedDiffArray = diff.ffi.CAttributedDiffArray;
const CAttributedDiffEntry = diff.ffi.CAttributedDiffEntry;

const CCommitArray = diff.ffi.CCommitArray;
const CCommitEntry = diff.ffi.CCommitEntry;

const ErrorCode = diff.ffi.ErrorCode;
const Operation = diff.ffi.Operation;

const fromError = diff.ffi.fromError;
const onCancelSignal = diff.onCancelSignal;
const signalLoopThread = diff.signalLoopThread;

pub export fn upac_diff_packages(repo_path_c: CSlice, from_ref_c: CSlice, to_ref_c: CSlice, out_c: *CPackageDiffArray) callconv(.C) i32 {
    validateDiffPackagesRequest(repo_path_c, from_ref_c, to_ref_c, out_c) catch |err| return @intFromEnum(fromError(err, Operation.diff));

    const cancellable = c_libs.g_cancellable_new();
    defer c_libs.g_object_unref(cancellable);

    const sigint_src = c_libs.g_unix_signal_source_new(std.posix.SIG.INT);
    const sigterm_src = c_libs.g_unix_signal_source_new(std.posix.SIG.TERM);

    const signal_ctx = c_libs.g_main_context_new();
    defer c_libs.g_main_context_unref(signal_ctx);

    c_libs.g_source_set_callback(sigint_src, @ptrCast(&onCancelSignal), cancellable, null);
    _ = c_libs.g_source_attach(sigint_src, signal_ctx);
    c_libs.g_source_unref(sigint_src);

    c_libs.g_source_set_callback(sigterm_src, @ptrCast(&onCancelSignal), cancellable, null);
    _ = c_libs.g_source_attach(sigterm_src, signal_ctx);
    c_libs.g_source_unref(sigterm_src);

    var signal_loop = c_libs.g_main_loop_new(signal_ctx, 0);
    var signal_thread = std.Thread.spawn(.{}, signalLoopThread, .{signal_loop.?}) catch null;

    signal_loop = c_libs.g_main_loop_new(signal_ctx, 0);
    signal_thread = std.Thread.spawn(.{}, signalLoopThread, .{signal_loop.?}) catch null;
    defer {
        if (signal_loop) |loop| {
            c_libs.g_main_loop_quit(loop);
        }
        if (signal_thread) |thread| thread.join();
        if (signal_loop) |loop| {
            c_libs.g_main_loop_unref(loop);
        }
    }

    const pkg_entries = diff.diffPackages(repo_path_c.toSlice(), from_ref_c.toSlice(), to_ref_c.toSlice(), cancellable, diff.ffi.allocator()) catch |err| return @intFromEnum(fromError(err, Operation.diff));

    const entries_c = diff.ffi.allocator().alloc(CPackageDiffEntry, pkg_entries.len) catch {
        for (pkg_entries) |entry| diff.ffi.allocator().free(entry.name);
        diff.ffi.allocator().free(pkg_entries);
        return @intFromEnum(ErrorCode.out_of_memory);
    };

    for (entries_c, 0..) |*entry_c, index| {
        entry_c.* = .{
            .name = CSlice.fromSlice(pkg_entries[index].name),
            .kind = switch (pkg_entries[index].kind) {
                .added => .added,
                .removed => .removed,
                .updated => .updated,
            },
        };
    }
    diff.ffi.allocator().free(pkg_entries);

    out_c.* = .{ .ptr = entries_c.ptr, .len = entries_c.len };
    return @intFromEnum(ErrorCode.ok);
}

fn validateDiffPackagesRequest(repo_path_c: CSlice, from_ref_c: CSlice, to_ref_c: CSlice, out_c: *CPackageDiffArray) !void {
    if (repo_path_c.isEmpty()) return error.InvalidEntry;
    if (from_ref_c.isEmpty()) return error.InvalidEntry;
    if (to_ref_c.isEmpty()) return error.InvalidEntry;
    if (std.mem.eql(u8, from_ref_c.toSlice(), to_ref_c.toSlice())) return error.InvalidEntry;

    _ = out_c;
}

pub export fn upac_diff_packages_free(c_out: *CPackageDiffArray) callconv(.C) void {
    const allocator = diff.ffi.allocator();
    const entries = c_out.toSlice();

    for (entries) |entry| allocator.free(entry.name.toSlice());

    diff.ffi.allocator().free(entries);
}

pub export fn upac_diff_files_attributed(repo_path_c: CSlice, from_ref_c: CSlice, to_ref_c: CSlice, root_path_c: CSlice, db_path_c: CSlice, out_c: *CAttributedDiffArray) callconv(.C) i32 {
    validateListCommitsRequest(repo_path_c, from_ref_c) catch return @intFromEnum(fromError(error.InvalidEntry, Operation.diff));
    validateListCommitsRequest(repo_path_c, to_ref_c) catch return @intFromEnum(fromError(error.InvalidEntry, Operation.diff));

    const cancellable = c_libs.g_cancellable_new();
    defer c_libs.g_object_unref(cancellable);

    const sigint_src = c_libs.g_unix_signal_source_new(std.posix.SIG.INT);
    const sigterm_src = c_libs.g_unix_signal_source_new(std.posix.SIG.TERM);

    const signal_ctx = c_libs.g_main_context_new();
    defer c_libs.g_main_context_unref(signal_ctx);

    c_libs.g_source_set_callback(sigint_src, @ptrCast(&onCancelSignal), cancellable, null);
    _ = c_libs.g_source_attach(sigint_src, signal_ctx);
    c_libs.g_source_unref(sigint_src);

    c_libs.g_source_set_callback(sigterm_src, @ptrCast(&onCancelSignal), cancellable, null);
    _ = c_libs.g_source_attach(sigterm_src, signal_ctx);
    c_libs.g_source_unref(sigterm_src);

    var signal_loop = c_libs.g_main_loop_new(signal_ctx, 0);
    var signal_thread = std.Thread.spawn(.{}, signalLoopThread, .{signal_loop.?}) catch null;

    signal_loop = c_libs.g_main_loop_new(signal_ctx, 0);
    signal_thread = std.Thread.spawn(.{}, signalLoopThread, .{signal_loop.?}) catch null;
    defer {
        if (signal_loop) |loop| {
            c_libs.g_main_loop_quit(loop);
        }
        if (signal_thread) |thread| thread.join();
        if (signal_loop) |loop| {
            c_libs.g_main_loop_unref(loop);
        }
    }

    const entries = diff.diffFilesAttributed(repo_path_c.toSlice(), from_ref_c.toSlice(), to_ref_c.toSlice(), root_path_c.toSlice(), db_path_c.toSlice(), cancellable, diff.ffi.allocator()) catch |err| return @intFromEnum(fromError(err, Operation.diff));

    const entries_c = diff.ffi.allocator().alloc(CAttributedDiffEntry, entries.len) catch {
        for (entries) |entry| {
            diff.ffi.allocator().free(entry.path);
            diff.ffi.allocator().free(entry.package_name);
        }
        diff.ffi.allocator().free(entries);
        return @intFromEnum(ErrorCode.out_of_memory);
    };

    for (entries_c, 0..) |*entry_c, index| {
        entry_c.* = .{
            .path = CSlice.fromSlice(entries[index].path),
            .kind = @enumFromInt(@intFromEnum(entries[index].kind)),
            .package_name = CSlice.fromSlice(entries[index].package_name),
        };
    }
    diff.ffi.allocator().free(entries);

    out_c.* = .{ .ptr = entries_c.ptr, .len = entries_c.len };
    return @intFromEnum(ErrorCode.ok);
}

fn validateListCommitsRequest(repo_path: CSlice, branch: CSlice) !void {
    if (repo_path.isEmpty()) return error.InvalidEntry;
    if (branch.isEmpty()) return error.InvalidEntry;
}

pub export fn upac_diff_files_attributed_free(out_c: *CAttributedDiffArray) callconv(.C) void {
    const entries = out_c.toSlice();
    for (entries) |entry| {
        diff.ffi.allocator().free(entry.path.toSlice());
        diff.ffi.allocator().free(entry.package_name.toSlice());
    }
    diff.ffi.allocator().free(entries);
}

pub export fn upac_list_packages(repo_path_c: CSlice, branch_c: CSlice, db_path_c: CSlice, out_c: *CPackageMetaArray) callconv(.C) i32 {
    validateListPackagesRequest(repo_path_c, branch_c, db_path_c) catch return @intFromEnum(fromError(error.InvalidEntry, Operation.list));

    const cancellable = c_libs.g_cancellable_new();
    defer c_libs.g_object_unref(cancellable);

    const sigint_src = c_libs.g_unix_signal_source_new(std.posix.SIG.INT);
    const sigterm_src = c_libs.g_unix_signal_source_new(std.posix.SIG.TERM);

    const signal_ctx = c_libs.g_main_context_new();
    defer c_libs.g_main_context_unref(signal_ctx);

    c_libs.g_source_set_callback(sigint_src, @ptrCast(&onCancelSignal), cancellable, null);
    _ = c_libs.g_source_attach(sigint_src, signal_ctx);
    c_libs.g_source_unref(sigint_src);

    c_libs.g_source_set_callback(sigterm_src, @ptrCast(&onCancelSignal), cancellable, null);
    _ = c_libs.g_source_attach(sigterm_src, signal_ctx);
    c_libs.g_source_unref(sigterm_src);

    var signal_loop = c_libs.g_main_loop_new(signal_ctx, 0);
    var signal_thread = std.Thread.spawn(.{}, signalLoopThread, .{signal_loop.?}) catch null;

    signal_loop = c_libs.g_main_loop_new(signal_ctx, 0);
    signal_thread = std.Thread.spawn(.{}, signalLoopThread, .{signal_loop.?}) catch null;
    defer {
        if (signal_loop) |loop| {
            c_libs.g_main_loop_quit(loop);
        }
        if (signal_thread) |thread| thread.join();
        if (signal_loop) |loop| {
            c_libs.g_main_loop_unref(loop);
        }
    }

    const packages = diff.listPackages(repo_path_c.toSlice(), branch_c.toSlice(), db_path_c.toSlice(), cancellable, diff.ffi.allocator()) catch |err| return @intFromEnum(fromError(err, Operation.list));

    const entries_c = diff.ffi.allocator().alloc(CPackageMeta, packages.len) catch {
        for (packages) |pkg| data.freePackageMeta(pkg, diff.ffi.allocator());
        diff.ffi.allocator().free(packages);
        return @intFromEnum(ErrorCode.out_of_memory);
    };

    for (entries_c, 0..) |*entry_c, index| {
        const pkg = packages[index];
        entry_c.* = .{
            .name = CSlice.fromSlice(pkg.name),
            .version = CSlice.fromSlice(pkg.version),
            .size = @intCast(pkg.size),
            .architecture = CSlice.fromSlice(pkg.architecture),
            .author = CSlice.fromSlice(pkg.author),
            .description = CSlice.fromSlice(pkg.description),
            .license = CSlice.fromSlice(pkg.license),
            .url = CSlice.fromSlice(pkg.url),
            .packager = CSlice.fromSlice(pkg.packager),
            .installed_at = pkg.installed_at,
            .checksum = CSlice.fromSlice(pkg.checksum),
        };
    }
    diff.ffi.allocator().free(packages);

    out_c.* = .{ .ptr = entries_c.ptr, .len = entries_c.len };
    return @intFromEnum(ErrorCode.ok);
}

fn validateListPackagesRequest(repo_path: CSlice, branch: CSlice, db_path: CSlice) !void {
    if (repo_path.isEmpty()) return error.InvalidEntry;
    if (branch.isEmpty()) return error.InvalidEntry;
    if (db_path.isEmpty()) return error.InvalidEntry;
}

fn freeCPackageMeta(meta: *CPackageMeta, allocator: std.mem.Allocator) void {
    allocator.free(meta.name.toSlice());
    allocator.free(meta.version.toSlice());
    allocator.free(meta.architecture.toSlice());
    allocator.free(meta.author.toSlice());
    allocator.free(meta.description.toSlice());
    allocator.free(meta.license.toSlice());
    allocator.free(meta.url.toSlice());
    allocator.free(meta.packager.toSlice());
    allocator.free(meta.checksum.toSlice());
}

pub export fn upac_packages_free(out_c: *CPackageMetaArray) callconv(.C) void {
    const entries = out_c.toSlice();
    for (entries) |*entry| freeCPackageMeta(entry, diff.ffi.allocator());
    diff.ffi.allocator().free(entries);
}

pub export fn upac_list_commits(repo_path_c: CSlice, branch_c: CSlice, out_c: *CCommitArray) callconv(.C) i32 {
    validateListCommitsRequest(repo_path_c, branch_c) catch return @intFromEnum(fromError(error.InvalidEntry, Operation.list));

    const cancellable = c_libs.g_cancellable_new();
    defer c_libs.g_object_unref(cancellable);

    const sigint_src = c_libs.g_unix_signal_source_new(std.posix.SIG.INT);
    const sigterm_src = c_libs.g_unix_signal_source_new(std.posix.SIG.TERM);

    const signal_ctx = c_libs.g_main_context_new();
    defer c_libs.g_main_context_unref(signal_ctx);

    c_libs.g_source_set_callback(sigint_src, @ptrCast(&onCancelSignal), cancellable, null);
    _ = c_libs.g_source_attach(sigint_src, signal_ctx);
    c_libs.g_source_unref(sigint_src);

    c_libs.g_source_set_callback(sigterm_src, @ptrCast(&onCancelSignal), cancellable, null);
    _ = c_libs.g_source_attach(sigterm_src, signal_ctx);
    c_libs.g_source_unref(sigterm_src);

    var signal_loop = c_libs.g_main_loop_new(signal_ctx, 0);
    var signal_thread = std.Thread.spawn(.{}, signalLoopThread, .{signal_loop.?}) catch null;

    signal_loop = c_libs.g_main_loop_new(signal_ctx, 0);
    signal_thread = std.Thread.spawn(.{}, signalLoopThread, .{signal_loop.?}) catch null;
    defer {
        if (signal_loop) |loop| {
            c_libs.g_main_loop_quit(loop);
        }
        if (signal_thread) |thread| thread.join();
        if (signal_loop) |loop| {
            c_libs.g_main_loop_unref(loop);
        }
    }

    const commit_entries = diff.listCommits(repo_path_c.toSlice(), branch_c.toSlice(), cancellable, diff.ffi.allocator()) catch |err| return @intFromEnum(fromError(err, Operation.list));

    const entries_c = diff.ffi.allocator().alloc(CCommitEntry, commit_entries.len) catch {
        for (commit_entries) |entry| {
            diff.ffi.allocator().free(entry.checksum);
            diff.ffi.allocator().free(entry.subject);
        }
        diff.ffi.allocator().free(commit_entries);
        return @intFromEnum(ErrorCode.out_of_memory);
    };

    for (commit_entries, 0..) |entry, index| {
        entries_c[index] = .{
            .checksum = CSlice.fromSlice(entry.checksum),
            .subject = CSlice.fromSlice(entry.subject),
        };
    }
    diff.ffi.allocator().free(commit_entries);

    out_c.* = .{ .ptr = entries_c.ptr, .len = entries_c.len };
    return @intFromEnum(ErrorCode.ok);
}

fn validateDiffFilesAttributedRequest(repo_path: CSlice, from_ref: CSlice, to_ref: CSlice, root_path: CSlice, db_path: CSlice) !void {
    if (root_path.isEmpty()) return error.InvalidEntry;
    if (repo_path.isEmpty()) return error.InvalidEntry;

    if (from_ref.isEmpty()) return error.InvalidEntry;
    if (to_ref.isEmpty()) return error.InvalidEntry;

    if (db_path.isEmpty()) return error.InvalidEntry;

    if (std.mem.eql(u8, from_ref.toSlice(), to_ref.toSlice())) return error.InvalidEntry;
}

pub export fn upac_commits_free(out_c: *CCommitArray) callconv(.C) void {
    const allocator = diff.ffi.allocator();
    const entries = out_c.toSlice();
    for (entries) |entry| {
        allocator.free(entry.checksum.toSlice());
        allocator.free(entry.subject.toSlice());
    }
    allocator.free(entries);
}
