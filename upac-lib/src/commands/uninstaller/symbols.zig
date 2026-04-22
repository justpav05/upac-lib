// ── Imports ─────────────────────────────────────────────────────────────────────
const uninstaller = @import("uninstaller.zig");
const std = uninstaller.std;

const CSlice = uninstaller.ffi.CSlice;
const CUninstallRequest = uninstaller.ffi.CUninstallRequest;
const UninstallProgressEvent = uninstaller.ffi.UninstallProgressEvent;

const ErrorCode = uninstaller.ffi.ErrorCode;
const Operation = uninstaller.ffi.Operation;
const fromError = uninstaller.ffi.fromError;

// An exported function for deleting a package. It extracts the parameters (paths, package name, retry limits) and initiates the deletion process
pub export fn upac_uninstall(uninstall_request_c: CUninstallRequest) callconv(.C) i32 {
    uninstall_request_c.validate() catch |err| return @intFromEnum(fromError(err, Operation.uninstall));

    const packages_names_c_null = uninstall_request_c.package_names orelse return @intFromEnum(fromError(error.InvalidEntry, Operation.install));

    const packages_names_c = packages_names_c_null[0..uninstall_request_c.package_names_len];

    const package_names = uninstaller.ffi.allocator().alloc([]const u8, packages_names_c.len) catch
        return @intFromEnum(ErrorCode.out_of_memory);
    defer uninstaller.ffi.allocator().free(package_names);

    for (packages_names_c, 0..) |package_name_c, index| {
        package_names[index] = package_name_c.toSlice();
    }

    const uninstall_data = uninstaller.UninstallData{
        .package_names = package_names,
        .repo_path = uninstall_request_c.repo_path.toSlice(),
        .root_path = uninstall_request_c.root_path.toSlice(),
        .db_path = uninstall_request_c.db_path.toSlice(),
        .branch = uninstall_request_c.branch.toSlice(),
        .prefix_directory = uninstall_request_c.prefix_directory.toSlice(),
        .max_retries = uninstall_request_c.max_retries,
        .on_progress = uninstall_request_c.on_progress,
        .progress_ctx = uninstall_request_c.progress_ctx,
    };

    uninstaller.UninstallerMachine.run(uninstall_data, uninstaller.ffi.allocator()) catch |err|
        return @intFromEnum(fromError(err, Operation.uninstall));

    return @intFromEnum(ErrorCode.ok);
}

fn onUninstallProgress(event: UninstallProgressEvent, pkg: CSlice, ctx: ?*anyopaque) callconv(.C) void {
    _ = ctx;
    _ = event;
    _ = pkg;
}
