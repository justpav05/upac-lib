const std = @import("std");

// ── Types imports ─────────────────────────────────────────────────────────────────
const types = @import("upac-types");
const data = @import("upac-data");
const file = @import("upac-file");

// ── Functions imports ─────────────────────────────────────────────────────────────────
const init = @import("upac-init");
const installer = @import("upac-installer");
const uninstaller = @import("upac-uninstaller");
const rollback = @import("upac-rollback");

// ── C types imports ─────────────────────────────────────────────────────────────────
const CSlice = types.CSlice;

const CSliceArray = types.CSliceArray;

const CPackageMeta = types.CPackageMeta;
const CPackageFiles = types.CPackageFiles;

const CInstallRequest = types.CInstallRequest;
const CUninstallRequest = types.CUninstallRequest;
const CCommitRequest = types.CCommitRequest;

const CCommitEntry = types.CCommitEntry;
const CCommitArray = types.CCommitArray;

const CDiffArray = types.CDiffArray;
const CDiffEntry = types.CDiffEntry;

const CSystemPaths = types.CSystemPaths;

const CRepoMode = types.CRepoMode;

// ── Error codes imports ─────────────────────────────────────────────────────────────────
const ErrorCode = types.ErrorCode;

// ── Converts from C to Zig ────────────────────────────────────────────────────────
fn toMeta(c_package_metadata: CPackageMeta) data.PackageMeta {
    return .{
        .name = c_package_metadata.name.toSlice(),
        .version = c_package_metadata.version.toSlice(),
        .author = c_package_metadata.author.toSlice(),
        .description = c_package_metadata.description.toSlice(),
        .license = c_package_metadata.license.toSlice(),
        .url = c_package_metadata.url.toSlice(),
        .installed_at = c_package_metadata.installed_at,
        .checksum = c_package_metadata.checksum.toSlice(),
    };
}

fn toFiles(c_package_files: CPackageFiles) data.PackageFiles {
    const c_packages_paths = c_package_files.paths.toSlice();
    const packages_paths = @as([*][]const u8, @ptrCast(c_packages_paths.ptr))[0..c_packages_paths.len];

    return .{
        .name = c_package_files.name.toSlice(),
        .paths = packages_paths,
    };
}

// ── Data API ──────────────────────────────────────────────────────────────
pub export fn upac_db_add_package(database_path: CSlice, c_package_meta: CPackageMeta, c_package_files: CPackageFiles) callconv(.C) i32 {
    const allocator = types.allocator();

    // Конвертируем пути из CSlice в [][]const u8
    const c_package_paths = c_package_files.paths.toSlice();
    var package_paths = allocator.alloc([]const u8, c_package_paths.len) catch return @intFromEnum(ErrorCode.out_of_memory);
    defer allocator.free(package_paths);

    for (c_package_paths, 0..) |c_slice_path, index| package_paths[index] = c_slice_path.toSlice();

    const zig_package_meta = toMeta(c_package_meta);
    const zig_package_files = data.PackageFiles{
        .name = c_package_files.name.toSlice(),
        .paths = package_paths,
    };

    data.addPackage(database_path.toSlice(), zig_package_meta, zig_package_files, types.allocator()) catch |err| return @intFromEnum(types.fromError(err));

    return @intFromEnum(ErrorCode.ok);
}

pub export fn upac_db_remove_package(database_path: CSlice, package_name: CSlice) callconv(.C) i32 {
    data.removePackage(database_path.toSlice(), package_name.toSlice(), types.allocator()) catch |err| return @intFromEnum(types.fromError(err));
    return @intFromEnum(ErrorCode.ok);
}

pub export fn upac_db_get_meta(c_database_path: CSlice, c_package_name: CSlice, c_package_meta: *CPackageMeta) callconv(.C) i32 {
    const allocator = types.allocator();

    const package_meta = data.getMeta(c_database_path.toSlice(), c_package_name.toSlice(), allocator) catch |err| return @intFromEnum(types.fromError(err));

    c_package_meta.* = .{
        .name = CSlice.fromSlice(package_meta.name),
        .version = CSlice.fromSlice(package_meta.version),
        .author = CSlice.fromSlice(package_meta.author),
        .description = CSlice.fromSlice(package_meta.description),
        .license = CSlice.fromSlice(package_meta.license),
        .url = CSlice.fromSlice(package_meta.url),
        .installed_at = package_meta.installed_at,
        .checksum = CSlice.fromSlice(package_meta.checksum),
    };

    return @intFromEnum(ErrorCode.ok);
}

pub export fn upac_meta_free(c_package_meta: *CPackageMeta) callconv(.C) void {
    const allocator = types.allocator();

    allocator.free(c_package_meta.name.toSlice());
    allocator.free(c_package_meta.version.toSlice());
    allocator.free(c_package_meta.author.toSlice());
    allocator.free(c_package_meta.description.toSlice());
    allocator.free(c_package_meta.license.toSlice());
    allocator.free(c_package_meta.url.toSlice());
    allocator.free(c_package_meta.checksum.toSlice());
}

pub export fn upac_db_get_files(c_database_path: CSlice, c_name: CSlice, c_package_files: *CPackageFiles) callconv(.C) i32 {
    const allocator = types.allocator();

    const package_files = data.getFiles(c_database_path.toSlice(), c_name.toSlice(), allocator) catch |err| return @intFromEnum(types.fromError(err));

    // Конвертируем [][]const u8 → []CSlice
    const c_package_paths = allocator.alloc(CSlice, package_files.paths.len) catch {
        for (package_files.paths) |package_file_path| allocator.free(package_file_path);
        allocator.free(package_files.paths);

        return @intFromEnum(ErrorCode.out_of_memory);
    };

    for (package_files.paths, 0..) |package_file_path, index| c_package_paths[index] = CSlice.fromSlice(package_file_path);

    c_package_files.* = .{
        .name = CSlice.fromSlice(package_files.name),
        .paths = .{ .ptr = c_package_paths.ptr, .len = c_package_paths.len },
    };

    return @intFromEnum(ErrorCode.ok);
}

pub export fn upac_files_free(c_package_files: *CPackageFiles) callconv(.C) void {
    const allocator = types.allocator();
    const package_paths = c_package_files.paths.toSlice();

    for (package_paths) |package_path| allocator.free(package_path.toSlice());
    allocator.free(package_paths);
    allocator.free(c_package_files.name.toSlice());
}

/// Получить список всех пакетов.
/// Вызывающий освобождает через upac_list_free.
pub export fn upac_db_list_packages(c_database_path: CSlice, c_packages_list: *CSliceArray) callconv(.C) i32 {
    const allocator = types.allocator();

    const packages_name = data.listPackages(c_database_path.toSlice(), allocator) catch |err|
        return @intFromEnum(types.fromError(err));

    const c_packages_names = allocator.alloc(CSlice, packages_name.len) catch {
        for (packages_name) |package_name| allocator.free(package_name);
        allocator.free(packages_name);

        return @intFromEnum(ErrorCode.out_of_memory);
    };

    for (packages_name, 0..) |package_name, index| c_packages_names[index] = CSlice.fromSlice(package_name);
    allocator.free(packages_name);

    c_packages_list.* = .{ .ptr = c_packages_names.ptr, .len = c_packages_names.len };
    return @intFromEnum(ErrorCode.ok);
}

/// Освобождает список пакетов полученный из upac_db_list_packages.
pub export fn upac_list_free(c_list: *CSliceArray) callconv(.C) void {
    const allocator = types.allocator();
    const slices = c_list.toSlice();

    for (slices) |slice| allocator.free(slice.toSlice());
    allocator.free(slices);
}

// ── Installer API ─────────────────────────────────────────────────────────────
/// Установить пакет.
pub export fn upac_install(c_install_data: CInstallRequest) callconv(.C) i32 {
    const allocator = types.allocator();

    // Конвертируем пути из CPackageMeta
    const zig_installer_data = installer.InstallData{
        .package_meta = toMeta(c_install_data.meta),
        .root_path = c_install_data.root_path.toSlice(),
        .repo_path = c_install_data.repo_path.toSlice(),
        .package_path = c_install_data.package_path.toSlice(),
        .database_path = c_install_data.db_path.toSlice(),
        .max_retries = c_install_data.max_retries,
    };

    installer.install(zig_installer_data, allocator) catch |err| return @intFromEnum(types.fromError(err));

    return @intFromEnum(ErrorCode.ok);
}

// ── Uninstaller API ───────────────────────────────────────────────────────────
pub export fn upac_uninstall(c_uninstall_request: CUninstallRequest) callconv(.C) i32 {
    const allocator = types.allocator();

    const zig_uninstall_data = uninstaller.UninstallData{
        .package_name = c_uninstall_request.package_name.toSlice(),
        .root_path = c_uninstall_request.root_path.toSlice(),
        .repo_path = c_uninstall_request.repo_path.toSlice(),
        .database_path = c_uninstall_request.db_path.toSlice(),
        .max_retries = c_uninstall_request.max_retries,
    };

    uninstaller.uninstall(zig_uninstall_data, allocator) catch |err|
        return @intFromEnum(types.fromError(err));

    return @intFromEnum(ErrorCode.ok);
}

// ── rollback API ────────────────────────────────────────────────────────────────
/// Создать коммит rollback.
pub export fn upac_ostree_commit(c_commit_request: CCommitRequest) callconv(.C) i32 {
    const allocator = types.allocator();

    const c_packages_meta = c_commit_request.packages[0..c_commit_request.packages_len];
    var zig_package_meta = allocator.alloc(data.PackageMeta, c_packages_meta.len) catch return @intFromEnum(ErrorCode.out_of_memory);
    defer allocator.free(zig_package_meta);

    for (c_packages_meta, 0..) |c_packge_meta, index| zig_package_meta[index] = toMeta(c_packge_meta);

    const zig_request = rollback.OstreeCommitRequest{
        .repo_path = c_commit_request.repo_path.toSlice(),
        .content_path = c_commit_request.content_path.toSlice(),
        .branch = c_commit_request.branch.toSlice(),
        .operation = switch (c_commit_request.operation) {
            .install => .install,
            .remove => .remove,
            .manual => .manual,
        },
        .packages = zig_package_meta,
        .database_path = c_commit_request.db_path.toSlice(),
    };

    rollback.commit(zig_request, allocator) catch |err| return @intFromEnum(types.fromError(err));

    return @intFromEnum(ErrorCode.ok);
}

pub export fn upac_refresh(c_repo_path: CSlice, c_content_path: CSlice, c_root_path: CSlice, c_branch: CSlice, c_database_path: CSlice) callconv(.C) i32 {
    const allocator = types.allocator();

    rollback.refresh(
        c_repo_path.toSlice(),
        c_content_path.toSlice(),
        c_root_path.toSlice(),
        c_branch.toSlice(),
        c_database_path.toSlice(),
        allocator,
    ) catch |err| return @intFromEnum(types.fromError(err));

    return @intFromEnum(ErrorCode.ok);
}

/// Получить diff между двумя коммитами.
/// Вызывающий освобождает через upac_diff_free.
pub export fn upac_ostree_diff(c_repo_path: CSlice, c_from_ref: CSlice, c_to_ref: CSlice, c_diff_out: *CDiffArray) callconv(.C) i32 {
    const allocator = types.allocator();

    const diff_entries = rollback.diff(
        c_repo_path.toSlice(),
        c_from_ref.toSlice(),
        c_to_ref.toSlice(),
        allocator,
    ) catch |err| return @intFromEnum(types.fromError(err));

    const c_entries = allocator.alloc(CDiffEntry, diff_entries.len) catch {
        for (diff_entries) |diff_entry| allocator.free(diff_entry.path);
        allocator.free(diff_entries);

        return @intFromEnum(ErrorCode.out_of_memory);
    };

    for (c_entries, 0..) |*package_meta, index| {
        package_meta.* = .{
            .path = CSlice.fromSlice(diff_entries[index].path),
            .kind = @enumFromInt(@intFromEnum(diff_entries[index].kind)),
        };
    }
    allocator.free(diff_entries);

    c_diff_out.* = .{ .ptr = c_entries.ptr, .len = c_entries.len };
    return @intFromEnum(ErrorCode.ok);
}

/// Освобождает CDiffArray полученный из upac_ostree_diff.
pub export fn upac_diff_free(c_diff: *CDiffArray) callconv(.C) void {
    const allocator = types.allocator();
    const entries = c_diff.toSlice();

    for (entries) |entry| allocator.free(entry.path.toSlice());
    allocator.free(entries);
}

pub export fn upac_ostree_list_commits(c_repo_path: CSlice, c_branch: CSlice, c_commits: *CCommitArray) callconv(.C) i32 {
    const allocator = types.allocator();

    const commit_entries = rollback.listCommits(
        c_repo_path.toSlice(),
        c_branch.toSlice(),
        allocator,
    ) catch |err| return @intFromEnum(types.fromError(err));

    const c_commit_entries = allocator.alloc(CCommitEntry, commit_entries.len) catch {
        for (commit_entries) |entry| {
            allocator.free(entry.checksum);
            allocator.free(entry.subject);
        }
        allocator.free(commit_entries);
        return @intFromEnum(ErrorCode.out_of_memory);
    };

    for (commit_entries, 0..) |entry, index| {
        c_commit_entries[index] = .{
            .checksum = CSlice.fromSlice(entry.checksum),
            .subject = CSlice.fromSlice(entry.subject),
        };
    }
    allocator.free(commit_entries);

    c_commits.* = .{ .ptr = c_commit_entries.ptr, .len = c_commit_entries.len };
    return @intFromEnum(ErrorCode.ok);
}

pub export fn upac_commits_free(c_commits: *CCommitArray) callconv(.C) void {
    const allocator = types.allocator();
    const entries = c_commits.toSlice();

    for (entries) |entry| {
        allocator.free(entry.checksum.toSlice());
        allocator.free(entry.subject.toSlice());
    }

    allocator.free(entries);
}

/// Откатить на предыдущий коммит.
pub export fn upac_ostree_rollback(c_repo_path: CSlice, c_content_path: CSlice, c_branch: CSlice, c_commit_hash: CSlice) callconv(.C) i32 {
    rollback.rollback(
        c_repo_path.toSlice(),
        c_content_path.toSlice(),
        c_branch.toSlice(),
        c_commit_hash.toSlice(),
        types.allocator(),
    ) catch |err| return @intFromEnum(types.fromError(err));

    return @intFromEnum(ErrorCode.ok);
}

// ── Init API ──────────────────────────────────────────────────────────────────
/// Инициализировать структуру директорий системы.
pub export fn upac_init_system(c_system_paths: CSystemPaths, c_repo_mode: CRepoMode) callconv(.C) i32 {
    const zig_system_paths = init.SystemPaths{
        .ostree_path = c_system_paths.ostree_path.toSlice(),
        .repo_path = c_system_paths.repo_path.toSlice(),
        .db_path = c_system_paths.db_path.toSlice(),
    };

    const zig_repo_mode: init.RepoMode = switch (c_repo_mode) {
        .archive => .archive,
        .bare => .bare,
        .bare_user => .bare_user,
    };

    init.initSystem(zig_system_paths, zig_repo_mode, types.allocator()) catch |err| return @intFromEnum(types.fromError(err));

    return @intFromEnum(ErrorCode.ok);
}
