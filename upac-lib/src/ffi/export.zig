const std = @import("std");

const alloc = @import("alloc.zig");

const types = @import("types.zig");

const errors = @import("errors.zig");

const db = @import("upac-database");

const inst = @import("upac-installer");

const ost = @import("upac-ostree");

const init_mod = @import("upac-init");

const CSlice = types.CSlice;
const CSliceArray = types.CSliceArray;

const CPackageMeta = types.CPackageMeta;
const CPackageFiles = types.CPackageFiles;

const CInstallRequest = types.CInstallRequest;
const CCommitRequest = types.CCommitRequest;

const CDiffArray = types.CDiffArray;
const CDiffEntry = types.CDiffEntry;

const CSystemPaths = types.CSystemPaths;

const CRepoMode = types.CRepoMode;

const ErrorCode = errors.ErrorCode;

// ── Конвертеры C → Zig ────────────────────────────────────────────────────────

fn toMeta(c: CPackageMeta) db.PackageMeta {
    return .{
        .name = c.name.toSlice(),
        .version = c.version.toSlice(),
        .author = c.author.toSlice(),
        .description = c.description.toSlice(),
        .license = c.license.toSlice(),
        .url = c.url.toSlice(),
        .installed_at = c.installed_at,
        .checksum = c.checksum.toSlice(),
    };
}

fn toFiles(c: CPackageFiles) db.PackageFiles {
    // Paths: [*]CSlice → [][]const u8 — живут в памяти вызывающего
    const c_paths = c.paths.toSlice();
    // Zig slice над C памятью — без копирования, lifetime у вызывающего
    const paths = @as([*][]const u8, @ptrCast(c_paths.ptr))[0..c_paths.len];
    return .{
        .name = c.name.toSlice(),
        .paths = paths,
    };
}

// ── Database API ──────────────────────────────────────────────────────────────
pub export fn upac_db_add_package(
    db_path: CSlice,
    meta: CPackageMeta,
    files: CPackageFiles,
) callconv(.C) i32 {
    const allocator = alloc.allocator();

    // Конвертируем пути из CSlice в [][]const u8
    const c_paths = files.paths.toSlice();
    var paths = allocator.alloc([]const u8, c_paths.len) catch
        return @intFromEnum(ErrorCode.out_of_memory);
    defer allocator.free(paths);

    for (c_paths, 0..) |p, i| paths[i] = p.toSlice();

    const zig_meta = toMeta(meta);
    const zig_files = db.PackageFiles{
        .name = files.name.toSlice(),
        .paths = paths,
    };

    db.addPackage(db_path.toSlice(), zig_meta, zig_files, allocator) catch |err|
        return @intFromEnum(errors.fromError(err));

    return @intFromEnum(ErrorCode.ok);
}

/// Удалить пакет из базы данных.
pub export fn upac_db_remove_package(
    db_path: CSlice,
    name: CSlice,
) callconv(.C) i32 {
    db.removePackage(db_path.toSlice(), name.toSlice(), alloc.allocator()) catch |err|
        return @intFromEnum(errors.fromError(err));
    return @intFromEnum(ErrorCode.ok);
}

/// Получить метаданные пакета.
/// Заполняет out_meta. Вызывающий освобождает через upac_meta_free.
pub export fn upac_db_get_meta(
    db_path: CSlice,
    name: CSlice,
    out_meta: *CPackageMeta,
) callconv(.C) i32 {
    const allocator = alloc.allocator();

    const meta = db.getMeta(db_path.toSlice(), name.toSlice(), allocator) catch |err|
        return @intFromEnum(errors.fromError(err));

    out_meta.* = .{
        .name = CSlice.fromSlice(meta.name),
        .version = CSlice.fromSlice(meta.version),
        .author = CSlice.fromSlice(meta.author),
        .description = CSlice.fromSlice(meta.description),
        .license = CSlice.fromSlice(meta.license),
        .url = CSlice.fromSlice(meta.url),
        .installed_at = meta.installed_at,
        .checksum = CSlice.fromSlice(meta.checksum),
    };

    return @intFromEnum(ErrorCode.ok);
}

pub export fn upac_meta_free(meta: *CPackageMeta) callconv(.C) void {
    const allocator = alloc.allocator();
    allocator.free(meta.name.toSlice());
    allocator.free(meta.version.toSlice());
    allocator.free(meta.author.toSlice());
    allocator.free(meta.description.toSlice());
    allocator.free(meta.license.toSlice());
    allocator.free(meta.url.toSlice());
    allocator.free(meta.checksum.toSlice());
}

/// Получить список файлов пакета.
/// Вызывающий освобождает через upac_files_free.
pub export fn upac_db_get_files(
    db_path: CSlice,
    name: CSlice,
    out_files: *CPackageFiles,
) callconv(.C) i32 {
    const allocator = alloc.allocator();

    const files = db.getFiles(db_path.toSlice(), name.toSlice(), allocator) catch |err|
        return @intFromEnum(errors.fromError(err));

    // Конвертируем [][]const u8 → []CSlice
    const c_paths = allocator.alloc(CSlice, files.paths.len) catch {
        for (files.paths) |p| allocator.free(p);
        allocator.free(files.paths);
        return @intFromEnum(ErrorCode.out_of_memory);
    };

    for (files.paths, 0..) |p, i| c_paths[i] = CSlice.fromSlice(p);

    out_files.* = .{
        .name = CSlice.fromSlice(files.name),
        .paths = .{ .ptr = c_paths.ptr, .len = c_paths.len },
    };

    return @intFromEnum(ErrorCode.ok);
}

/// Освобождает память занятую CPackageFiles.
pub export fn upac_files_free(files: *CPackageFiles) callconv(.C) void {
    const allocator = alloc.allocator();
    const paths = files.paths.toSlice();
    for (paths) |p| allocator.free(p.toSlice());
    allocator.free(paths);
    allocator.free(files.name.toSlice());
}

/// Получить список всех пакетов.
/// Вызывающий освобождает через upac_list_free.
pub export fn upac_db_list_packages(
    db_path: CSlice,
    out_list: *CSliceArray,
) callconv(.C) i32 {
    const allocator = alloc.allocator();

    const names = db.listPackages(db_path.toSlice(), allocator) catch |err|
        return @intFromEnum(errors.fromError(err));

    const c_names = allocator.alloc(CSlice, names.len) catch {
        for (names) |n| allocator.free(n);
        allocator.free(names);
        return @intFromEnum(ErrorCode.out_of_memory);
    };

    for (names, 0..) |n, i| c_names[i] = CSlice.fromSlice(n);
    // Оригинальный [][]const u8 больше не нужен — данные живут в CSlice
    allocator.free(names);

    out_list.* = .{ .ptr = c_names.ptr, .len = c_names.len };
    return @intFromEnum(ErrorCode.ok);
}

/// Освобождает список пакетов полученный из upac_db_list_packages.
pub export fn upac_list_free(list: *CSliceArray) callconv(.C) void {
    const allocator = alloc.allocator();
    const slices = list.toSlice();
    for (slices) |s| allocator.free(s.toSlice());
    allocator.free(slices);
}

// ── Installer API ─────────────────────────────────────────────────────────────

/// Установить пакет.
pub export fn upac_install(request: CInstallRequest) callconv(.C) i32 {
    const allocator = alloc.allocator();

    // Конвертируем пути из CPackageMeta
    const zig_request = inst.InstallRequest{
        .meta = toMeta(request.meta),
        .root_path = request.root_path.toSlice(),
        .repo_path = request.repo_path.toSlice(),
        .package_path = request.package_path.toSlice(),
        .db_path = request.db_path.toSlice(),
        .max_retries = request.max_retries,
    };

    inst.install(zig_request, allocator) catch |err|
        return @intFromEnum(errors.fromError(err));

    return @intFromEnum(ErrorCode.ok);
}

// ── OStree API ────────────────────────────────────────────────────────────────

/// Создать коммит OStree.
pub export fn upac_ostree_commit(request: CCommitRequest) callconv(.C) i32 {
    const allocator = alloc.allocator();

    // Конвертируем массив пакетов
    const c_pkgs = request.packages[0..request.packages_len];
    var zig_pkgs = allocator.alloc(db.PackageMeta, c_pkgs.len) catch
        return @intFromEnum(ErrorCode.out_of_memory);
    defer allocator.free(zig_pkgs);

    for (c_pkgs, 0..) |p, i| zig_pkgs[i] = toMeta(p);

    const zig_request = ost.OstreeCommitRequest{
        .repo_path = request.repo_path.toSlice(),
        .content_path = request.content_path.toSlice(),
        .branch = request.branch.toSlice(),
        .operation = request.operation.toSlice(),
        .packages = zig_pkgs,
        .db_path = request.db_path.toSlice(),
    };

    ost.commit(zig_request, allocator) catch |err|
        return @intFromEnum(errors.fromError(err));

    return @intFromEnum(ErrorCode.ok);
}

/// Получить diff между двумя коммитами.
/// Вызывающий освобождает через upac_diff_free.
pub export fn upac_ostree_diff(
    repo_path: CSlice,
    from_ref: CSlice,
    to_ref: CSlice,
    out_diff: *CDiffArray,
) callconv(.C) i32 {
    const allocator = alloc.allocator();

    const entries = ost.diff(
        repo_path.toSlice(),
        from_ref.toSlice(),
        to_ref.toSlice(),
        allocator,
    ) catch |err| return @intFromEnum(errors.fromError(err));

    // Конвертируем []DiffEntry → []CDiffEntry
    const c_entries = allocator.alloc(CDiffEntry, entries.len) catch {
        for (entries) |e| allocator.free(e.path);
        allocator.free(entries);
        return @intFromEnum(ErrorCode.out_of_memory);
    };

    for (entries, 0..) |e, i| {
        c_entries[i] = .{
            .path = CSlice.fromSlice(e.path),
            .kind = @enumFromInt(@intFromEnum(e.kind)),
        };
    }
    allocator.free(entries);

    out_diff.* = .{ .ptr = c_entries.ptr, .len = c_entries.len };
    return @intFromEnum(ErrorCode.ok);
}

/// Освобождает CDiffArray полученный из upac_ostree_diff.
pub export fn upac_diff_free(diff: *CDiffArray) callconv(.C) void {
    const allocator = alloc.allocator();
    const entries = diff.toSlice();
    for (entries) |e| allocator.free(e.path.toSlice());
    allocator.free(entries);
}

/// Откатить на предыдущий коммит.
pub export fn upac_ostree_rollback(
    repo_path: CSlice,
    content_path: CSlice,
    branch: CSlice,
) callconv(.C) i32 {
    ost.rollback(
        repo_path.toSlice(),
        content_path.toSlice(),
        branch.toSlice(),
        alloc.allocator(),
    ) catch |err| return @intFromEnum(errors.fromError(err));

    return @intFromEnum(ErrorCode.ok);
}

// ── Init API ──────────────────────────────────────────────────────────────────

/// Инициализировать структуру директорий системы.
pub export fn upac_init_system(
    paths: CSystemPaths,
    mode: CRepoMode,
) callconv(.C) i32 {
    const zig_paths = init_mod.SystemPaths{
        .ostree_path = paths.ostree_path.toSlice(),
        .repo_path = paths.repo_path.toSlice(),
        .db_path = paths.db_path.toSlice(),
    };

    const zig_mode: init_mod.RepoMode = switch (mode) {
        .archive => .archive,
        .bare => .bare,
        .bare_user => .bare_user,
    };

    init_mod.initSystem(zig_paths, zig_mode, alloc.allocator()) catch |err|
        return @intFromEnum(errors.fromError(err));

    return @intFromEnum(ErrorCode.ok);
}
