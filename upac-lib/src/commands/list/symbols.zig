// ── Imports ─────────────────────────────────────────────────────────────────────
const list = @import("list.zig");
const std = list.std;
const c_libs = list.c_libs;
const data = list.data;

const PackageMeta = list.ffi.PackageMeta;

const CSlice = list.ffi.CSlice;
const CPackageMeta = list.ffi.CPackageMeta;

const CCommitArray = list.ffi.CCommitArray;
const CCommitEntry = list.ffi.CCommitEntry;

const ErrorCode = list.ffi.ErrorCode;
const Operation = list.ffi.Operation;

const check = list.check();

const fromError = list.ffi.fromError;

const onCancelSignal = list.onCancelSignal;
const signalLoopThread = list.signalLoopThread;

const PackageListInner = struct {
    packages: []PackageMeta,
    allocator: std.mem.Allocator,
};

const SignalHandle = struct {
    cancellable: *c_libs.GCancellable,
    signal_ctx: *c_libs.GMainContext,
    signal_loop: *c_libs.GMainLoop,
    thread: std.Thread,
};

pub export fn upac_list_packages(repo_path_c: CSlice, branch_c: CSlice, db_path_c: CSlice, out_c: **anyopaque) callconv(.C) i32 {
    validateListPackagesRequest(repo_path_c, branch_c, db_path_c) catch return @intFromEnum(fromError(error.InvalidEntry, Operation.list));

    const signals = setupCancellable() catch return @intFromEnum(fromError(error.DiffFailed, Operation.list));
    defer teardownCancellable(signals);

    const packages = list.listPackages(repo_path_c.toSlice(), branch_c.toSlice(), db_path_c.toSlice(), signals.cancellable, list.ffi.allocator()) catch |err| return @intFromEnum(fromError(err, Operation.list));

    const package_list_inner = list.ffi.allocator().create(PackageListInner) catch {
        for (packages) |pkg| data.freePackageMeta(pkg, list.ffi.allocator());
        list.ffi.allocator().free(packages);
        return @intFromEnum(ErrorCode.out_of_memory);
    };
    package_list_inner.* = .{ .packages = packages, .allocator = list.ffi.allocator() };

    out_c.* = package_list_inner;
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

pub export fn upac_packages_count(handle: *anyopaque) callconv(.C) usize {
    const package_list_inner = @as(*PackageListInner, @ptrCast(@alignCast(handle)));
    return package_list_inner.packages.len;
}

pub export fn upac_package_get_slice_field(handle: ?*anyopaque, index: usize, field: u8, out: ?*CSlice) callconv(.C) i32 {
    const out_ptr = out orelse return @intFromEnum(fromError(error.db_invalid_entry, Operation.list));
    const package_list_inner = @as(*PackageListInner, @ptrCast(@alignCast(handle)));
    if (index >= package_list_inner.packages.len) return @intFromEnum(fromError(error.db_invalid_entry, Operation.list));

    const package_meta = package_list_inner.packages[index];
    const result_field = switch (field) {
        0 => package_meta.name,
        1 => package_meta.version,
        2 => package_meta.architecture,
        3 => package_meta.author,
        4 => package_meta.description,
        5 => package_meta.license,
        6 => package_meta.url,
        7 => package_meta.packager,
        8 => package_meta.checksum,
        else => return @intFromEnum(fromError(error.db_invalid_entry, Operation.list)),
    };

    out_ptr.* = CSlice.fromSlice(result_field);
    return @intFromEnum(ErrorCode.ok);
}

pub export fn upac_package_get_int_field(handle: ?*anyopaque, index: usize, field: u8, out: ?*u32) callconv(.C) i32 {
    const out_ptr = out orelse return @intFromEnum(fromError(error.db_invalid_entry, Operation.list));
    const package_list_inner = @as(*PackageListInner, @ptrCast(@alignCast(handle)));
    if (index >= package_list_inner.packages.len) return @intFromEnum(fromError(error.db_invalid_entry, Operation.list));

    const package_meta = package_list_inner.packages[index];
    const result_field: u32 = switch (field) {
        9 => @intCast(package_meta.size),
        11 => @intCast(package_meta.installed_at),
        else => return @intFromEnum(fromError(error.db_invalid_entry, Operation.list)),
    };

    out_ptr.* = result_field;
    return @intFromEnum(ErrorCode.ok);
}

pub export fn upac_packages_free(handle: *anyopaque) callconv(.C) void {
    const package_list_inner = @as(*PackageListInner, @ptrCast(@alignCast(handle)));
    for (package_list_inner.packages) |package_meta| data.freePackageMeta(package_meta, package_list_inner.allocator);

    package_list_inner.allocator.free(package_list_inner.packages);
    package_list_inner.allocator.destroy(package_list_inner);
}

pub export fn upac_list_commits(repo_path_c: CSlice, branch_c: CSlice, out_c: *CCommitArray) callconv(.C) i32 {
    validateListCommitsRequest(repo_path_c, branch_c) catch return @intFromEnum(fromError(error.InvalidEntry, Operation.list));

    const signals = setupCancellable() catch return @intFromEnum(fromError(error.DiffFailed, Operation.list));
    defer teardownCancellable(signals);

    const commit_entries = list.listCommits(repo_path_c.toSlice(), branch_c.toSlice(), signals.cancellable, list.ffi.allocator()) catch |err| return @intFromEnum(fromError(err, Operation.list));

    const commit_entries_c = list.ffi.allocator().alloc(CCommitEntry, commit_entries.len) catch {
        for (commit_entries) |entry| {
            list.ffi.allocator().free(entry.checksum);
            list.ffi.allocator().free(entry.subject);
        }
        list.ffi.allocator().free(commit_entries);
        return @intFromEnum(ErrorCode.out_of_memory);
    };

    for (commit_entries, 0..) |commit_entry, index| {
        commit_entries_c[index] = .{
            .checksum = CSlice.fromSlice(commit_entry.checksum),
            .subject = CSlice.fromSlice(commit_entry.subject),
        };
    }
    list.ffi.allocator().free(commit_entries);

    out_c.* = .{ .ptr = commit_entries_c.ptr, .len = commit_entries_c.len };
    return @intFromEnum(ErrorCode.ok);
}

fn validateListCommitsRequest(repo_path: CSlice, branch: CSlice) !void {
    if (repo_path.isEmpty()) return error.InvalidEntry;
    if (branch.isEmpty()) return error.InvalidEntry;
}

pub export fn upac_commits_free(out_c: *CCommitArray) callconv(.C) void {
    const allocator = list.ffi.allocator();
    const entries = out_c.toSlice();
    for (entries) |entry| {
        allocator.free(entry.checksum.toSlice());
        allocator.free(entry.subject.toSlice());
    }
    allocator.free(entries);
}

fn setupCancellable() !SignalHandle {
    const cancellable = c_libs.g_cancellable_new();
    const signal_ctx = c_libs.g_main_context_new() orelse return error.DiffFailed;

    const sigint_src = c_libs.g_unix_signal_source_new(std.posix.SIG.INT);
    const sigterm_src = c_libs.g_unix_signal_source_new(std.posix.SIG.TERM);

    c_libs.g_source_set_callback(sigint_src, @ptrCast(&onCancelSignal), cancellable, null);
    c_libs.g_source_set_callback(sigterm_src, @ptrCast(&onCancelSignal), cancellable, null);
    _ = c_libs.g_source_attach(sigint_src, signal_ctx);
    _ = c_libs.g_source_attach(sigterm_src, signal_ctx);
    c_libs.g_source_unref(sigint_src);
    c_libs.g_source_unref(sigterm_src);

    const signal_loop = c_libs.g_main_loop_new(signal_ctx, 0) orelse return error.DiffFailed;
    const thread = try std.Thread.spawn(.{}, signalLoopThread, .{signal_loop});

    return .{ .cancellable = cancellable, .signal_ctx = signal_ctx, .signal_loop = signal_loop, .thread = thread };
}

fn teardownCancellable(h: SignalHandle) void {
    c_libs.g_main_loop_quit(h.signal_loop);
    h.thread.join();
    c_libs.g_main_loop_unref(h.signal_loop);
    c_libs.g_main_context_unref(h.signal_ctx);
    c_libs.g_object_unref(h.cancellable);
}
