// ── Imports ─────────────────────────────────────────────────────────────────────
const diff_module = @import("upac-diff");
const std = diff_module.std;
const c_libs = diff_module.c_libs;
const data = diff_module.data;

const CSlice = diff_module.ffi.CSlice;
const CArray = diff_module.ffi.CArray;
const CDiffRequest = diff_module.ffi.CUnmutatedRequest;

const CPackageDiffEntry = diff_module.ffi.CPackageDiffEntry;
const CAttributedDiffEntry = diff_module.ffi.CAttributedDiffEntry;

const ErrorCode = diff_module.ffi.ErrorCode;
const Operation = diff_module.ffi.Operation;

const fromError = diff_module.ffi.fromError;

pub fn diff_packages(diff_request_c: CDiffRequest, out_c: *CArray(CPackageDiffEntry)) callconv(.c) i32 {
    const required = [_]CSlice{ diff_request_c.repo_path, diff_request_c.from_commit_hash, diff_request_c.to_commit_hash };
    for (required) |field| {
        if (field.len == 0 or field.ptr[field.len] != 0) return @intFromEnum(fromError(error.InvalidEntry, Operation.diff));
    }

    const package_diff_entrys = diff_module.DiffMachine.runPackages(.{ .repo_path = diff_request_c.repo_path.asZ(), .from_ref = diff_request_c.from_commit_hash.asZ(), .to_ref = diff_request_c.to_commit_hash.asZ() }, diff_module.ffi.allocator()) catch |err| {
        if (err == error.Cancelled) diff_module.ffi.global_cancel.store(true, .release);
        return @intFromEnum(fromError(err, Operation.diff));
    };

    out_c.* = .{ .ptr = package_diff_entrys.ptr, .len = package_diff_entrys.len };
    return @intFromEnum(ErrorCode.ok);
}

pub fn diff_packages_free(c_out: *CArray(CPackageDiffEntry)) callconv(.c) void {
    const allocator = diff_module.ffi.allocator();
    const entries = c_out.toSlice();

    for (entries) |entry| allocator.free(entry.name.toSlice());

    diff_module.ffi.allocator().free(entries);
}

pub fn diff_files(diff_request_c: CDiffRequest, out_c: *CArray(CAttributedDiffEntry)) callconv(.c) i32 {
    const required = [_]CSlice{ diff_request_c.repo_path, diff_request_c.from_commit_hash, diff_request_c.to_commit_hash, diff_request_c.db_path };
    for (required) |field| {
        if (field.len == 0 or field.ptr[field.len] != 0) return @intFromEnum(fromError(error.InvalidEntry, Operation.diff));
    }

    const files_diff_entrys = diff_module.DiffMachine.runFiles(.{ .repo_path = diff_request_c.repo_path.asZ(), .from_ref = diff_request_c.from_commit_hash.asZ(), .to_ref = diff_request_c.to_commit_hash.asZ(), .db_path = diff_request_c.db_path.toSlice() }, diff_module.ffi.allocator()) catch |err| {
        if (err == error.Cancelled) diff_module.ffi.global_cancel.store(true, .release);
        return @intFromEnum(fromError(err, Operation.diff));
    };

    out_c.* = .{ .ptr = files_diff_entrys.ptr, .len = files_diff_entrys.len };
    return @intFromEnum(ErrorCode.ok);
}

pub fn diff_files_free(out_c: *CArray(CAttributedDiffEntry)) callconv(.c) void {
    const entries = out_c.toSlice();
    for (entries) |entry| {
        diff_module.ffi.allocator().free(entry.path.toSlice());
        diff_module.ffi.allocator().free(entry.package_name.toSlice());
    }
    diff_module.ffi.allocator().free(entries);
}
