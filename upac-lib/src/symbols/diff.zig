// ── Imports ─────────────────────────────────────────────────────────────────────
const diff = @import("upac-diff");
const std = diff.std;
const c_libs = diff.c_libs;
const data = diff.data;

const CSlice = diff.ffi.CSlice;

const CPackageDiffArray = diff.ffi.CPackageDiffArray;
const CPackageDiffEntry = diff.ffi.CPackageDiffEntry;

const CAttributedDiffArray = diff.ffi.CAttributedDiffArray;
const CAttributedDiffEntry = diff.ffi.CAttributedDiffEntry;

const ErrorCode = diff.ffi.ErrorCode;
const Operation = diff.ffi.Operation;

const files = diff.files;

const diffFilesAttributed = files.diffFilesAttributed;

const packages = diff.packages;

const diffPackages = packages.diffPackages;

const fromError = diff.ffi.fromError;

const onCancelSignal = diff.onCancelSignal;
const signalLoopThread = diff.signalLoopThread;

const SignalHandle = struct {
    cancellable: *c_libs.GCancellable,
    signal_ctx: *c_libs.GMainContext,
    signal_loop: *c_libs.GMainLoop,
    thread: std.Thread,
};

pub fn diff_packages(repo_path: CSlice, from_ref: CSlice, to_ref: CSlice, out_c: *CPackageDiffArray) callconv(.c) i32 {
    validateDiffPackagesRequest(repo_path, from_ref, to_ref, out_c) catch |err| return @intFromEnum(fromError(err, Operation.diff));

    var arena_allocator = std.heap.ArenaAllocator.init(diff.ffi.allocator());
    defer arena_allocator.deinit();

    const signals = setupCancellable() catch return @intFromEnum(fromError(error.DiffFailed, Operation.list));
    defer teardownCancellable(signals);

    const repo_path_c = arena_allocator.allocator().dupeZ(u8, repo_path.toSlice()) catch return @intFromEnum(fromError(error.AllocZFailed, Operation.uninstall));

    const from_ref_c = arena_allocator.allocator().dupeZ(u8, from_ref.toSlice()) catch return @intFromEnum(fromError(error.AllocZFailed, Operation.uninstall));

    const to_ref_c = arena_allocator.allocator().dupeZ(u8, to_ref.toSlice()) catch return @intFromEnum(fromError(error.AllocZFailed, Operation.uninstall));

    const pkg_entries = diffPackages(repo_path_c, from_ref_c, to_ref_c, signals.cancellable, diff.ffi.allocator()) catch |err| return @intFromEnum(fromError(err, Operation.diff));

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
    if (!repo_path_c.validate()) return error.InvalidEntry;
    if (!from_ref_c.validate()) return error.InvalidEntry;
    if (!to_ref_c.validate()) return error.InvalidEntry;
    if (std.mem.eql(u8, from_ref_c.toSlice(), to_ref_c.toSlice())) return error.InvalidEntry;

    _ = out_c;
}

pub fn diff_packages_free(c_out: *CPackageDiffArray) callconv(.c) void {
    const allocator = diff.ffi.allocator();
    const entries = c_out.toSlice();

    for (entries) |entry| allocator.free(entry.name.toSlice());

    diff.ffi.allocator().free(entries);
}

pub fn diff_files_attributed(repo_path: CSlice, from_ref: CSlice, to_ref: CSlice, root_path: CSlice, db_path: CSlice, out_c: *CAttributedDiffArray) callconv(.c) i32 {
    validateListCommitsRequest(repo_path, from_ref) catch return @intFromEnum(fromError(error.InvalidEntry, Operation.diff));
    validateListCommitsRequest(repo_path, to_ref) catch return @intFromEnum(fromError(error.InvalidEntry, Operation.diff));

    var arena_allocator = std.heap.ArenaAllocator.init(diff.ffi.allocator());
    defer arena_allocator.deinit();

    const signals = setupCancellable() catch return @intFromEnum(fromError(error.DiffFailed, Operation.list));
    defer teardownCancellable(signals);

    const repo_path_c = arena_allocator.allocator().dupeZ(u8, repo_path.toSlice()) catch return @intFromEnum(fromError(error.AllocZFailed, Operation.uninstall));

    const from_ref_c = arena_allocator.allocator().dupeZ(u8, from_ref.toSlice()) catch return @intFromEnum(fromError(error.AllocZFailed, Operation.uninstall));

    const to_ref_c = arena_allocator.allocator().dupeZ(u8, to_ref.toSlice()) catch return @intFromEnum(fromError(error.AllocZFailed, Operation.uninstall));

    const root_path_c = arena_allocator.allocator().dupeZ(u8, root_path.toSlice()) catch return @intFromEnum(fromError(error.AllocZFailed, Operation.uninstall));

    const entries = diffFilesAttributed(repo_path_c, from_ref_c, to_ref_c, root_path_c, db_path.toSlice(), signals.cancellable, diff.ffi.allocator()) catch |err| return @intFromEnum(fromError(err, Operation.diff));

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
    if (!repo_path.validate()) return error.InvalidEntry;
    if (!branch.validate()) return error.InvalidEntry;
}

pub fn diff_files_attributed_free(out_c: *CAttributedDiffArray) callconv(.c) void {
    const entries = out_c.toSlice();
    for (entries) |entry| {
        diff.ffi.allocator().free(entry.path.toSlice());
        diff.ffi.allocator().free(entry.package_name.toSlice());
    }
    diff.ffi.allocator().free(entries);
}

fn validateDiffFilesAttributedRequest(repo_path: CSlice, from_ref: CSlice, to_ref: CSlice, root_path: CSlice, db_path: CSlice) !void {
    if (!root_path.validate()) return error.InvalidEntry;
    if (!repo_path.validate()) return error.InvalidEntry;

    if (!from_ref.validate()) return error.InvalidEntry;
    if (!to_ref.validate()) return error.InvalidEntry;

    if (!db_path.validate()) return error.InvalidEntry;

    if (std.mem.eql(u8, from_ref.toSlice(), to_ref.toSlice())) return error.InvalidEntry;
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
