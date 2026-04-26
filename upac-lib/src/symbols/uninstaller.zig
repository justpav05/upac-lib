// ── Imports ─────────────────────────────────────────────────────────────────────
const uninstaller_module = @import("upac-uninstaller");
const std = uninstaller_module.std;

const CSlice = uninstaller_module.ffi.CSlice;
const CUninstallRequest = uninstaller_module.ffi.CUninstallRequest;
const UninstallProgressEvent = uninstaller_module.ffi.UninstallProgressEvent;

const ErrorCode = uninstaller_module.ffi.ErrorCode;
const Operation = uninstaller_module.ffi.Operation;
const fromError = uninstaller_module.ffi.fromError;

// An exported function for deleting a package. It extracts the parameters (paths, package name, retry limits) and initiates the deletion process
pub fn uninstall(uninstall_request_c: CUninstallRequest) callconv(.c) i32 {
    uninstall_request_c.validate() catch |err| return @intFromEnum(fromError(err, Operation.uninstall));

    var arena_allocator = std.heap.ArenaAllocator.init(uninstaller_module.ffi.allocator());
    defer arena_allocator.deinit();

    const packages_names_c_null = uninstall_request_c.package_names orelse return @intFromEnum(fromError(error.InvalidEntry, Operation.uninstall));

    const packages_names_c = packages_names_c_null[0..uninstall_request_c.package_names_len];

    const package_names = uninstaller_module.ffi.allocator().alloc([]const u8, packages_names_c.len) catch
        return @intFromEnum(ErrorCode.out_of_memory);
    defer uninstaller_module.ffi.allocator().free(package_names);

    for (packages_names_c, 0..) |package_name_c, index| {
        package_names[index] = package_name_c.toSlice();
    }

    const uninstall_data = uninstaller_module.UninstallData{
        .package_names = package_names,
        .branch = arena_allocator.allocator().dupeZ(u8, uninstall_request_c.branch.toSlice()) catch return @intFromEnum(fromError(error.AllocZFailed, Operation.uninstall)),

        .repo_path = arena_allocator.allocator().dupeZ(u8, uninstall_request_c.repo_path.toSlice()) catch return @intFromEnum(fromError(error.AllocZFailed, Operation.uninstall)),
        .root_path = arena_allocator.allocator().dupeZ(u8, uninstall_request_c.root_path.toSlice()) catch return @intFromEnum(fromError(error.AllocZFailed, Operation.uninstall)),
        .database_path = arena_allocator.allocator().dupeZ(u8, uninstall_request_c.db_path.toSlice()) catch return @intFromEnum(fromError(error.AllocZFailed, Operation.uninstall)),
        .prefix_path = arena_allocator.allocator().dupeZ(u8, uninstall_request_c.prefix_directory.toSlice()) catch return @intFromEnum(fromError(error.AllocZFailed, Operation.uninstall)),

        .on_progress = uninstall_request_c.on_progress,
        .progress_ctx = uninstall_request_c.progress_ctx,

        .max_retries = uninstall_request_c.max_retries,
    };

    uninstaller_module.UninstallerMachine.run(uninstall_data, uninstaller_module.ffi.allocator()) catch |err|
        return @intFromEnum(fromError(err, Operation.uninstall));

    return @intFromEnum(ErrorCode.ok);
}

fn onUninstallProgress(event: UninstallProgressEvent, pkg: CSlice, ctx: ?*anyopaque) callconv(.c) void {
    _ = ctx;
    _ = event;
    _ = pkg;
}
