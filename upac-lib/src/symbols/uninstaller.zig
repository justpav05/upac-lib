// ── Imports ─────────────────────────────────────────────────────────────────────
const uninstaller_module = @import("upac-uninstaller");
const std = uninstaller_module.std;

const CSlice = uninstaller_module.ffi.CSlice;
const CUninstallRequest = uninstaller_module.ffi.CMutatedRequest;
const UninstallProgressFn = uninstaller_module.ffi.UninstallProgressFn;
const UninstallProgressEvent = uninstaller_module.ffi.UninstallProgressEvent;

const ErrorCode = uninstaller_module.ffi.ErrorCode;
const Operation = uninstaller_module.ffi.Operation;
const fromError = uninstaller_module.ffi.fromError;

// An exported function for deleting a package. It extracts the parameters (paths, package name, retry limits) and initiates the deletion process
pub fn uninstall(uninstall_request_c: CUninstallRequest) callconv(.c) i32 {
    uninstall_request_c.validate() catch |err| return @intFromEnum(fromError(err, Operation.uninstall));

    const required_fields = [_]CSlice{ uninstall_request_c.repo_path, uninstall_request_c.root_path, uninstall_request_c.db_path, uninstall_request_c.branch, uninstall_request_c.prefix_directory };
    for (required_fields) |field| {
        if (field.len == 0 or field.ptr[field.len] != 0) return @intFromEnum(fromError(error.InvalidEntry, Operation.uninstall));
    }

    const packages_names_c_null = uninstall_request_c.package_names orelse return @intFromEnum(fromError(error.InvalidEntry, Operation.uninstall));
    if (uninstall_request_c.package_names_len == 0) return @intFromEnum(fromError(error.InvalidEntry, Operation.uninstall));

    const packages_names_c = packages_names_c_null[0..uninstall_request_c.package_names_len];
    for (packages_names_c) |name| {
        if (name.len == 0 or name.ptr[name.len] != 0) return @intFromEnum(fromError(error.InvalidEntry, Operation.uninstall));
    }

    const package_names = uninstaller_module.ffi.allocator().alloc([]const u8, packages_names_c.len) catch return @intFromEnum(ErrorCode.out_of_memory);
    defer uninstaller_module.ffi.allocator().free(package_names);

    for (packages_names_c, 0..) |name, i| package_names[i] = name.toSlice();

    const uninstall_data = uninstaller_module.UninstallData{
        .package_names = package_names,
        .branch = uninstall_request_c.branch.asZ(),
        .repo_path = uninstall_request_c.repo_path.asZ(),
        .root_path = uninstall_request_c.root_path.asZ(),
        .database_path = uninstall_request_c.db_path.asZ(),
        .prefix_path = uninstall_request_c.prefix_directory.asZ(),
        .on_progress = if (uninstall_request_c.on_progress) |cb| @as(UninstallProgressFn, @ptrCast(cb)) else null,
        .progress_ctx = uninstall_request_c.progress_ctx,
        .max_retries = uninstall_request_c.max_retries,
    };

    uninstaller_module.UninstallerMachine.run(uninstall_data, uninstaller_module.ffi.allocator()) catch |err|
        return @intFromEnum(fromError(err, Operation.uninstall));

    return @intFromEnum(ErrorCode.ok);
}
