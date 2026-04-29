// ── Imports ─────────────────────────────────────────────────────────────────────
const list_module = @import("upac-list");
const std = list_module.std;
const c_libs = list_module.c_libs;
const data = list_module.data;

const CSlice = list_module.ffi.CSlice;
const CArray = list_module.ffi.CArray;
const CPackageMeta = list_module.ffi.CPackageMeta;

const CCommitEntry = list_module.ffi.CCommitEntry;

const CListRequest = list_module.ffi.CUnmutatedRequest;

const ErrorCode = list_module.ffi.ErrorCode;
const Operation = list_module.ffi.Operation;

const fromError = list_module.ffi.fromError;

pub fn list_packages(list_request_c: CListRequest, out_c: *CArray(CPackageMeta)) callconv(.c) i32 {
    const required = [_]CSlice{ list_request_c.repo_path, list_request_c.branch, list_request_c.db_path };
    for (required) |field| {
        if (field.len == 0 or field.ptr[field.len] != 0)
            return @intFromEnum(fromError(error.InvalidEntry, Operation.list));
    }

    const packages = list_module.ListMachine.runPackages(.{
        .repo_path = list_request_c.repo_path.asZ(),
        .branch = list_request_c.branch.asZ(),
        .db_path = list_request_c.db_path.toSlice(),
    }, list_module.ffi.allocator()) catch |err| {
        if (err == error.Cancelled) list_module.ffi.global_cancel.store(true, .release);
        return @intFromEnum(fromError(err, Operation.list));
    };

    out_c.* = .{ .ptr = packages.ptr, .len = packages.len };
    return @intFromEnum(ErrorCode.ok);
}

pub fn packages_count(out_c: *CArray(CPackageMeta)) callconv(.c) usize {
    return out_c.len;
}

pub fn package_get_slice_field(out_c: *CArray(CPackageMeta), index: usize, field: u8, out: ?*CSlice) callconv(.c) i32 {
    const out_ptr = out orelse return @intFromEnum(fromError(error.InvalidEntry, Operation.list));
    if (index >= out_c.len) return @intFromEnum(fromError(error.InvalidEntry, Operation.list));

    const pkg = out_c.ptr[index];
    const result = switch (field) {
        0 => pkg.name,
        1 => pkg.version,
        2 => pkg.architecture,
        3 => pkg.author,
        4 => pkg.description,
        5 => pkg.license,
        6 => pkg.url,
        7 => pkg.packager,
        8 => pkg.checksum,
        else => return @intFromEnum(fromError(error.InvalidEntry, Operation.list)),
    };

    out_ptr.* = result; // уже CSlice, fromSlice не нужен
    return @intFromEnum(ErrorCode.ok);
}

pub fn package_get_int_field(out_c: *CArray(CPackageMeta), index: usize, field: u8, out: ?*u64) callconv(.c) i32 {
    const out_ptr = out orelse return @intFromEnum(fromError(error.InvalidEntry, Operation.list));
    if (index >= out_c.len) return @intFromEnum(fromError(error.InvalidEntry, Operation.list));

    const pkg = out_c.ptr[index];
    out_ptr.* = switch (field) {
        9 => @intCast(pkg.size),
        10 => @intCast(pkg.installed_at),
        else => return @intFromEnum(fromError(error.InvalidEntry, Operation.list)),
    };

    return @intFromEnum(ErrorCode.ok);
}

pub fn packages_free(package_meta_array_c: *CArray(CPackageMeta)) callconv(.c) void {
    const allocator = list_module.ffi.allocator();
    for (package_meta_array_c.toSlice()) |package_meta_c| {
        allocator.free(package_meta_c.name.toSlice());
        allocator.free(package_meta_c.version.toSlice());
        allocator.free(package_meta_c.architecture.toSlice());
        allocator.free(package_meta_c.author.toSlice());
        allocator.free(package_meta_c.description.toSlice());
        allocator.free(package_meta_c.license.toSlice());
        allocator.free(package_meta_c.url.toSlice());
        allocator.free(package_meta_c.packager.toSlice());
        allocator.free(package_meta_c.checksum.toSlice());
    }
    allocator.free(package_meta_array_c.toSlice());
}

pub fn list_commits(repo_path: CSlice, branch: CSlice, out_c: *CArray(CCommitEntry)) callconv(.c) i32 {
    const required = [_]CSlice{ repo_path, branch };
    for (required) |field| {
        if (field.len == 0 or field.ptr[field.len] != 0) return @intFromEnum(fromError(error.InvalidEntry, Operation.list));
    }

    const commit_entries = list_module.ListMachine.runCommits(.{
        .repo_path = repo_path.asZ(),
        .branch = branch.asZ(),
    }, list_module.ffi.allocator()) catch |err| {
        if (err == error.Cancelled) list_module.ffi.global_cancel.store(true, .release);
        return @intFromEnum(fromError(err, Operation.list));
    };

    out_c.* = .{ .ptr = commit_entries.ptr, .len = commit_entries.len };
    return @intFromEnum(ErrorCode.ok);
}

pub fn commits_free(out_c: *CArray(CCommitEntry)) callconv(.c) void {
    const allocator = list_module.ffi.allocator();
    const entries = out_c.toSlice();
    for (entries) |entry| {
        allocator.free(entry.checksum.toSlice());
        allocator.free(entry.subject.toSlice());
    }
    allocator.free(entries);
}
