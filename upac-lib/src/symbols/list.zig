// ── Imports ─────────────────────────────────────────────────────────────────────
const list_module = @import("upac-list");
const std = list_module.std;
const c_libs = list_module.c_libs;
const data = list_module.data;

const PackageMeta = list_module.ffi.PackageMeta;

const CSlice = list_module.ffi.CSlice;
const CPackageMeta = list_module.ffi.CPackageMeta;

const CCommitArray = list_module.ffi.CCommitArray;
const CCommitEntry = list_module.ffi.CCommitEntry;

const ErrorCode = list_module.ffi.ErrorCode;
const Operation = list_module.ffi.Operation;

const check = list_module.check();

const fromError = list_module.ffi.fromError;

const onCancelSignal = list_module.onCancelSignal;
const signalLoopThread = list_module.signalLoopThread;

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

pub fn upac_list_packages(repo_path: CSlice, branch: CSlice, db_path_c: CSlice, out_c: **anyopaque) callconv(.c) i32 {
    validateListPackagesRequest(repo_path, branch, db_path_c) catch return @intFromEnum(fromError(error.InvalidEntry, Operation.list));

    var arena_allocator = std.heap.ArenaAllocator.init(list_module.ffi.allocator());
    defer arena_allocator.deinit();

    const signals = setupCancellable() catch return @intFromEnum(fromError(error.DiffFailed, Operation.list));
    defer teardownCancellable(signals);

    const repo_path_c = arena_allocator.allocator().dupeZ(u8, repo_path.toSlice()) catch return @intFromEnum(fromError(error.AllocZFailed, Operation.uninstall));
    const branch_c = arena_allocator.allocator().dupeZ(u8, branch.toSlice()) catch return @intFromEnum(fromError(error.AllocZFailed, Operation.uninstall));

    const packages = list_module.listPackages(repo_path_c, branch_c, db_path_c.toSlice(), signals.cancellable, list_module.ffi.allocator()) catch |err| return @intFromEnum(fromError(err, Operation.list));

    const package_list_inner = list_module.ffi.allocator().create(PackageListInner) catch {
        for (packages) |pkg| data.freePackageMeta(pkg, list_module.ffi.allocator());
        list_module.ffi.allocator().free(packages);
        return @intFromEnum(ErrorCode.out_of_memory);
    };
    package_list_inner.* = .{ .packages = packages, .allocator = list_module.ffi.allocator() };

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

pub fn packages_count(handle: *anyopaque) callconv(.c) usize {
    const package_list_inner = @as(*PackageListInner, @ptrCast(@alignCast(handle)));
    return package_list_inner.packages.len;
}

pub fn package_get_slice_field(handle: ?*anyopaque, index: usize, field: u8, out: ?*CSlice) callconv(.c) i32 {
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

pub fn package_get_int_field(handle: ?*anyopaque, index: usize, field: u8, out: ?*u32) callconv(.c) i32 {
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

pub fn packages_free(handle: *anyopaque) callconv(.c) void {
    const package_list_inner = @as(*PackageListInner, @ptrCast(@alignCast(handle)));
    for (package_list_inner.packages) |package_meta| data.freePackageMeta(package_meta, package_list_inner.allocator);

    package_list_inner.allocator.free(package_list_inner.packages);
    package_list_inner.allocator.destroy(package_list_inner);
}

pub fn list_commits(repo_path: CSlice, branch: CSlice, out_c: *CCommitArray) callconv(.c) i32 {
    validateListCommitsRequest(repo_path, branch) catch return @intFromEnum(fromError(error.InvalidEntry, Operation.list));

    var arena_allocator = std.heap.ArenaAllocator.init(list_module.ffi.allocator());
    defer arena_allocator.deinit();

    const signals = setupCancellable() catch return @intFromEnum(fromError(error.DiffFailed, Operation.list));
    defer teardownCancellable(signals);

    const repo_path_c = arena_allocator.allocator().dupeZ(u8, repo_path.toSlice()) catch return @intFromEnum(fromError(error.AllocZFailed, Operation.uninstall));
    const branch_c = arena_allocator.allocator().dupeZ(u8, branch.toSlice()) catch return @intFromEnum(fromError(error.AllocZFailed, Operation.uninstall));

    const commit_entries = list_module.listCommits(repo_path_c, branch_c, signals.cancellable, list_module.ffi.allocator()) catch |err| return @intFromEnum(fromError(err, Operation.list));

    const commit_entries_c = list_module.ffi.allocator().alloc(CCommitEntry, commit_entries.len) catch {
        for (commit_entries) |entry| {
            list_module.ffi.allocator().free(entry.checksum);
            list_module.ffi.allocator().free(entry.subject);
        }
        list_module.ffi.allocator().free(commit_entries);
        return @intFromEnum(ErrorCode.out_of_memory);
    };

    for (commit_entries, 0..) |commit_entry, index| {
        commit_entries_c[index] = .{
            .checksum = CSlice.fromSlice(commit_entry.checksum),
            .subject = CSlice.fromSlice(commit_entry.subject),
        };
    }
    list_module.ffi.allocator().free(commit_entries);

    out_c.* = .{ .ptr = commit_entries_c.ptr, .len = commit_entries_c.len };
    return @intFromEnum(ErrorCode.ok);
}

fn validateListCommitsRequest(repo_path: CSlice, branch: CSlice) !void {
    if (repo_path.isEmpty()) return error.InvalidEntry;
    if (branch.isEmpty()) return error.InvalidEntry;
}

pub fn commits_free(out_c: *CCommitArray) callconv(.c) void {
    const allocator = list_module.ffi.allocator();
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
