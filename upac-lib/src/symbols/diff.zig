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

const SignalHandle = struct {
    cancellable: *c_libs.GCancellable,
    signal_ctx: *c_libs.GMainContext,
    signal_loop: *c_libs.GMainLoop,
    thread: std.Thread,
};

pub fn diff_packages(repo_path: CSlice, from_ref: CSlice, to_ref: CSlice, out_c: *CPackageDiffArray) callconv(.c) i32 {
    var arena_allocator = std.heap.ArenaAllocator.init(diff.ffi.allocator());
    defer arena_allocator.deinit();

    const cancellable = c_libs.g_cancellable_new() orelse return @intFromEnum(ErrorCode.out_of_memory);
    defer if (cancellable) |cancel| c_libs.g_object_unref(cancel);

    var gerror: ?*c_libs.GError = null;
    defer if (gerror != null) |err| c_libs.g_error_free(err);

    const pkg_entries = diffPackages(repo_path.ptr, from_ref.ptr, to_ref.ptr, cancellable, &gerror, diff.ffi.allocator()) catch |err| return @intFromEnum(fromError(err, Operation.diff));

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

pub fn diff_packages_free(c_out: *CPackageDiffArray) callconv(.c) void {
    const allocator = diff.ffi.allocator();
    const entries = c_out.toSlice();

    for (entries) |entry| allocator.free(entry.name.toSlice());

    diff.ffi.allocator().free(entries);
}

pub fn diff_files_attributed(repo_path: CSlice, from_ref: CSlice, to_ref: CSlice, root_path: CSlice, db_path: CSlice, out_c: *CAttributedDiffArray) callconv(.c) i32 {
    var arena_allocator = std.heap.ArenaAllocator.init(diff.ffi.allocator());
    defer arena_allocator.deinit();

    const repo_path_c = arena_allocator.allocator().dupeZ(u8, repo_path.toSlice()) catch return @intFromEnum(fromError(error.AllocZFailed, Operation.uninstall));

    const from_ref_c = arena_allocator.allocator().dupeZ(u8, from_ref.toSlice()) catch return @intFromEnum(fromError(error.AllocZFailed, Operation.uninstall));

    const to_ref_c = arena_allocator.allocator().dupeZ(u8, to_ref.toSlice()) catch return @intFromEnum(fromError(error.AllocZFailed, Operation.uninstall));

    const root_path_c = arena_allocator.allocator().dupeZ(u8, root_path.toSlice()) catch return @intFromEnum(fromError(error.AllocZFailed, Operation.uninstall));

    const entries = diffFilesAttributed(repo_path_c, from_ref_c, to_ref_c, root_path_c, db_path.toSlice(), c_libs.g_cancellable_new() orelse return @intFromEnum(ErrorCode.out_of_memory), diff.ffi.allocator()) catch |err| return @intFromEnum(fromError(err, Operation.diff));

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

pub fn diff_files_attributed_free(out_c: *CAttributedDiffArray) callconv(.c) void {
    const entries = out_c.toSlice();
    for (entries) |entry| {
        diff.ffi.allocator().free(entry.path.toSlice());
        diff.ffi.allocator().free(entry.package_name.toSlice());
    }
    diff.ffi.allocator().free(entries);
}
