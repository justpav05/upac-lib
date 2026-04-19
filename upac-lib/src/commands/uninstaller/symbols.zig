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
pub export fn upac_uninstall(c_uninstall_request: CUninstallRequest) callconv(.C) i32 {
    const allocator = uninstaller.ffi.allocator();

    const names_c = c_uninstall_request.package_names[0..c_uninstall_request.package_names_len];

    const package_names = allocator.alloc([]const u8, names_c.len) catch
        return @intFromEnum(ErrorCode.out_of_memory);
    defer allocator.free(package_names);

    for (names_c, 0..) |name_c, index| {
        package_names[index] = name_c.toSlice();
    }

    const uninstall_data = uninstaller.UninstallData{
        .package_names = package_names,
        .repo_path = c_uninstall_request.repo_path.toSlice(),
        .root_path = c_uninstall_request.root_path.toSlice(),
        .db_path = c_uninstall_request.db_path.toSlice(),
        .branch = c_uninstall_request.branch.toSlice(),
        .max_retries = c_uninstall_request.max_retries,
        .on_progress = c_uninstall_request.on_progress,
        .progress_ctx = c_uninstall_request.progress_ctx,
    };

    uninstaller.UninstallerMachine.run(uninstall_data, allocator) catch |err|
        return @intFromEnum(fromError(err, Operation.uninstall));

    return @intFromEnum(ErrorCode.ok);
}

fn onUninstallProgress(event: UninstallProgressEvent, pkg: CSlice, ctx: ?*anyopaque) callconv(.C) void {
    _ = ctx;
    const package_name = pkg.toSlice();
    switch (event) {
        .Verifying => std.debug.print("→ verifying {s}...\n", .{package_name}),
        .OpeningRepo => std.debug.print("→ opening repo...\n", .{}),
        .CheckingInstalled => std.debug.print("→ checking if {s} is installed...\n", .{package_name}),
        .RemoveDbFiles => std.debug.print("→ removing database for {s}...\n", .{package_name}),
        .ProcessingFiles => std.debug.print("→ processing files for {s}...\n", .{package_name}),
        .Committing => std.debug.print("→ committing {s}...\n", .{package_name}),
        .Ready => std.debug.print("✓ {s} uninstalled\n", .{package_name}),
        .Failed => std.debug.print("✗ {s} failed\n", .{package_name}),
        else => {},
    }
}
