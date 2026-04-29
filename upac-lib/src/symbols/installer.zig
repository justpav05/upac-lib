// ── Imports ─────────────────────────────────────────────────────────────────────
const installer_module = @import("upac-installer");
const std = installer_module.std;
const PackageMeta = installer_module.ffi.PackageMeta;
const InstallProgressEvent = installer_module.ffi.InstallProgressEvent;

const CSlice = installer_module.ffi.CSlice;
const CPackageMeta = installer_module.ffi.CPackageMeta;
const CInstallRequest = installer_module.ffi.CMutatedRequest;
const InstallProgressFn = installer_module.ffi.InstallProgressFn;

const ErrorCode = installer_module.ffi.ErrorCode;
const Operation = installer_module.ffi.Operation;
const fromError = installer_module.ffi.fromError;

// The main entry point for package installation. It gathers installation data from the request, initializes the installation engine, and returns an error code as an i32
pub fn install(install_request_c: CInstallRequest) callconv(.c) i32 {
    install_request_c.validate() catch |err| return @intFromEnum(fromError(err, Operation.install));

    const install_entries = collectInstallEntries(install_request_c, installer_module.ffi.allocator()) catch |err| return @intFromEnum(fromError(err, Operation.install));
    defer installer_module.ffi.allocator().free(install_entries);

    const install_data = installer_module.InstallData{
        .packages = install_entries,
        .branch = install_request_c.branch.asZ(),
        .repo_path = install_request_c.repo_path.asZ(),
        .root_path = install_request_c.root_path.asZ(),
        .database_path = install_request_c.db_path.asZ(),
        .prefix_path = install_request_c.prefix_directory.asZ(),
        .on_progress = if (install_request_c.on_progress) |cb| @as(InstallProgressFn, @ptrCast(cb)) else null,
        .progress_ctx = install_request_c.progress_ctx,
        .max_retries = install_request_c.max_retries,
    };

    installer_module.InstallerMachine.run(install_data, installer_module.ffi.allocator()) catch |err| {
        if (err == error.Cancelled) installer_module.ffi.global_cancel.store(true, .release);
        return @intFromEnum(fromError(err, Operation.install));
    };

    return @intFromEnum(ErrorCode.ok);
}

fn collectInstallEntries(c_install_request: CInstallRequest, allocator: std.mem.Allocator) ![]installer_module.InstallEntry {
    if (c_install_request.packages_count > 0 and c_install_request.packages == null) {
        return error.InvalidEntry;
    }

    const pkgs_ptr = c_install_request.packages orelse return error.InvalidEntry;

    const packages_entrys_c = pkgs_ptr[0..c_install_request.packages_count];

    const install_entries = allocator.alloc(installer_module.InstallEntry, packages_entrys_c.len) catch return error.OutOfMemory;
    errdefer allocator.free(install_entries);

    for (packages_entrys_c, 0..) |package_entry_c, index| {
        const package_meta_c: *CPackageMeta = @ptrCast(@alignCast(package_entry_c.meta));

        install_entries[index] = .{
            .package = .{
                .meta = .{
                    .name = package_meta_c.name.toSlice(),
                    .version = package_meta_c.version.toSlice(),
                    .size = @intCast(package_meta_c.size),
                    .architecture = package_meta_c.architecture.toSlice(),
                    .author = package_meta_c.author.toSlice(),
                    .description = package_meta_c.description.toSlice(),
                    .license = package_meta_c.license.toSlice(),
                    .url = package_meta_c.url.toSlice(),
                    .packager = package_meta_c.packager.toSlice(),
                    .installed_at = package_meta_c.installed_at,
                    .checksum = package_meta_c.checksum.toSlice(),
                },
                .files = &.{},
            },
            .temp_path = package_entry_c.temp_path.asZ(),
            .checksum = package_entry_c.checksum.asZ(),
        };
    }

    return install_entries;
}
