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
pub export fn upac_install(install_request_c: CInstallRequest) callconv(.C) i32 {
    install_request_c.validate() catch |err| return @intFromEnum(fromError(err, Operation.install));

    var arena_allocator = std.heap.ArenaAllocator.init(installer.ffi.allocator());
    defer arena_allocator.deinit();

    const install_entries = collectInstallEntries(install_request_c, installer.ffi.allocator()) catch |err| return @intFromEnum(fromError(err, Operation.install));
    defer installer.ffi.allocator().free(install_entries);

    const install_data = installer.InstallData{
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

    installer.InstallerMachine.run(install_data, installer.ffi.allocator()) catch |err|
        return @intFromEnum(fromError(err, Operation.install));

    return @intFromEnum(ErrorCode.ok);
}

fn onInstallProgress(event: InstallProgressEvent, pkg: CSlice, ctx: ?*anyopaque) callconv(.C) void {
    _ = ctx;
    _ = event;
    _ = pkg;
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

fn collectInstallEntries(c_install_request: CInstallRequest, allocator: std.mem.Allocator) ![]installer.InstallEntry {
    if (c_install_request.packages_count > 0 and c_install_request.packages == null) {
        return error.InvalidEntry;
    }

    const pkgs_ptr = c_install_request.packages orelse return error.InvalidEntry;

    const packages_entrys_c = pkgs_ptr[0..c_install_request.packages_count];

    const install_entries = allocator.alloc(installer.InstallEntry, packages_entrys_c.len) catch return error.OutOfMemory;
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
