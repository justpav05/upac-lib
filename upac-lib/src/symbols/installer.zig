// ── Imports ─────────────────────────────────────────────────────────────────────
const installer_module = @import("upac-installer");
const std = installer_module.std;
const PackageMeta = installer_module.ffi.PackageMeta;
const InstallProgressEvent = installer_module.ffi.InstallProgressEvent;

const CSlice = installer_module.ffi.CSlice;
const CPackageMeta = installer_module.ffi.CPackageMeta;
const CInstallRequest = installer_module.ffi.CInstallRequest;

const ErrorCode = installer_module.ffi.ErrorCode;
const Operation = installer_module.ffi.Operation;
const fromError = installer_module.ffi.fromError;

// The main entry point for package installation. It gathers installation data from the request, initializes the installation engine, and returns an error code as an i32
pub fn install(install_request_c: CInstallRequest) callconv(.c) i32 {
    var arena_allocator = std.heap.ArenaAllocator.init(installer_module.ffi.allocator());
    defer arena_allocator.deinit();

    const install_entries = collectInstallEntries(install_request_c, installer_module.ffi.allocator()) catch |err| return @intFromEnum(fromError(err, Operation.install));
    defer installer_module.ffi.allocator().free(install_entries);

    const install_data = installer_module.InstallData{
        .packages = install_entries,
        .branch = arena_allocator.allocator().dupeZ(u8, install_request_c.branch.toSlice()) catch return @intFromEnum(fromError(error.AllocZFailed, Operation.uninstall)),

        .repo_path = arena_allocator.allocator().dupeZ(u8, install_request_c.repo_path.toSlice()) catch return @intFromEnum(fromError(error.AllocZFailed, Operation.uninstall)),
        .root_path = arena_allocator.allocator().dupeZ(u8, install_request_c.root_path.toSlice()) catch return @intFromEnum(fromError(error.AllocZFailed, Operation.uninstall)),
        .database_path = arena_allocator.allocator().dupeZ(u8, install_request_c.db_path.toSlice()) catch return @intFromEnum(fromError(error.AllocZFailed, Operation.uninstall)),
        .prefix_path = arena_allocator.allocator().dupeZ(u8, install_request_c.prefix_directory.toSlice()) catch return @intFromEnum(fromError(error.AllocZFailed, Operation.uninstall)),

        .on_progress = install_request_c.on_progress,
        .progress_ctx = install_request_c.progress_ctx,

        .max_retries = install_request_c.max_retries,
    };

    installer_module.InstallerMachine.run(install_data, installer_module.ffi.allocator()) catch |err| {
        if (err == error.Cancelled) installer_module.ffi.global_cancel.store(true, .release);
        return @intFromEnum(fromError(err, Operation.list));
    };

    return @intFromEnum(ErrorCode.ok);
}

// An internal helper function that converts the C struct CPackageMeta to native PackageMeta, translating CSlices into regular slices ([]const u8)
fn toMeta(c_package_meta: CPackageMeta) PackageMeta {
    return .{
        .name = c_package_meta.name.toSlice(),
        .version = c_package_meta.version.toSlice(),
        .size = @intCast(c_package_meta.size),
        .architecture = c_package_meta.architecture.toSlice(),
        .author = c_package_meta.author.toSlice(),
        .description = c_package_meta.description.toSlice(),
        .license = c_package_meta.license.toSlice(),
        .url = c_package_meta.url.toSlice(),
        .packager = c_package_meta.packager.toSlice(),
        .installed_at = c_package_meta.installed_at,
        .checksum = c_package_meta.checksum.toSlice(),
    };
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
        const package_meta: *CPackageMeta = @ptrCast(@alignCast(package_entry_c.meta));

        install_entries[index] = .{
            .package = .{
                .meta = toMeta(package_meta.*),
                .files = &.{},
            },
            .temp_path = package_entry_c.temp_path.toSlice(),
            .checksum = package_entry_c.checksum.toSlice(),
        };
    }

    return install_entries;
}
