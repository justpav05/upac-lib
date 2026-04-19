// ── Imports ─────────────────────────────────────────────────────────────────────
const installer = @import("installer.zig");
const std = installer.std;
const PackageMeta = installer.ffi.PackageMeta;
const InstallProgressEvent = installer.ffi.InstallProgressEvent;

const CSlice = installer.ffi.CSlice;
const CPackageMeta = installer.ffi.CPackageMeta;
const CInstallRequest = installer.ffi.CInstallRequest;

const ErrorCode = installer.ffi.ErrorCode;
const Operation = installer.ffi.Operation;
const fromError = installer.ffi.fromError;

// The main entry point for package installation. It gathers installation data from the request, initializes the installation engine, and returns an error code as an i32
pub export fn upac_install(c_install_request: CInstallRequest) callconv(.C) i32 {
    const allocator = installer.ffi.allocator();

    const packages_c = c_install_request.packages[0..c_install_request.packages_len];

    const install_entries = allocator.alloc(installer.InstallEntry, packages_c.len) catch
        return @intFromEnum(ErrorCode.out_of_memory);
    defer allocator.free(install_entries);

    for (packages_c, 0..) |c_entry, index| {
        install_entries[index] = .{ .package = .{ .meta = toMeta(c_entry.meta), .files = &.{} }, .temp_path = c_entry.temp_path.toSlice(), .checksum = c_entry.checksum.toSlice() };
    }

    const install_data = installer.InstallData{
        .packages = install_entries,
        .repo_path = c_install_request.repo_path.toSlice(),
        .root_path = c_install_request.root_path.toSlice(),
        .database_path = c_install_request.db_path.toSlice(),
        .branch = c_install_request.branch.toSlice(),
        .max_retries = c_install_request.max_retries,
        .on_progress = c_install_request.on_progress,
        .progress_ctx = c_install_request.progress_ctx,
    };

    installer.InstallerMachine.run(install_data, allocator) catch |err|
        return @intFromEnum(fromError(err, Operation.install));

    return @intFromEnum(ErrorCode.ok);
}

fn onInstallProgress(event: InstallProgressEvent, pkg: CSlice, ctx: ?*anyopaque) callconv(.C) void {
    _ = ctx;
    const package_name = pkg.toSlice();
    switch (event) {
        .Verifying => std.debug.print("→ verifying {s}...\n", .{package_name}),
        .CheckSpace => std.debug.print("→ checking space for {s}...\n", .{package_name}),
        .OpeningRepo => std.debug.print("→ opening repo...\n", .{}),
        .CheckingInstalled => std.debug.print("→ checking if {s} is installed...\n", .{package_name}),
        .WritingDatabase => std.debug.print("→ writing database for {s}...\n", .{package_name}),
        .ProcessingFiles => std.debug.print("→ processing files for {s}...\n", .{package_name}),
        .Committing => std.debug.print("→ committing {s}...\n", .{package_name}),
        .Checkout => std.debug.print("→ checking out {s}...\n", .{package_name}),

        .Done => std.debug.print("✓ {s} installed\n", .{package_name}),
        .Failed => std.debug.print("✗ {s} failed\n", .{package_name}),
        else => {},
    }
}

// An internal helper function that converts the C struct CPackageMeta to native PackageMeta, translating CSlices into regular slices ([]const u8)
fn toMeta(c_package_meta: CPackageMeta) PackageMeta {
    return .{
        .name = c_package_meta.name.toSlice(),
        .version = c_package_meta.version.toSlice(),
        .author = c_package_meta.author.toSlice(),
        .description = c_package_meta.description.toSlice(),
        .license = c_package_meta.license.toSlice(),
        .url = c_package_meta.url.toSlice(),
        .installed_at = c_package_meta.installed_at,
        .checksum = c_package_meta.checksum.toSlice(),
    };
}
