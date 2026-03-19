const std = @import("std");
const installer = @import("upac-installer");
const db = @import("upac-database");

const InstallRequest = installer.InstallRequest;
const PackageMeta = db.PackageMeta;

// ── Хелперы ───────────────────────────────────────────────────────────────────

/// Создаёт временную директорию и возвращает её путь.
/// Вызывающий обязан удалить через std.fs.deleteTreeAbsolute.
fn makeTmpDir(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    const path = try std.fs.path.join(allocator, &.{ "/tmp", name });
    std.fs.makeDirAbsolute(path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    return path;
}

/// Создаёт файл по абсолютному пути, включая промежуточные директории.
fn makeFile(path: []const u8, content: []const u8) !void {
    const dir = std.fs.path.dirname(path) orelse return error.InvalidPath;
    std.fs.makeDirAbsolute(dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = content });
}

/// Тестовые метаданные пакета
fn testMeta(name: []const u8) PackageMeta {
    return PackageMeta{
        .name = name,
        .version = "1.0.0",
        .author = "test",
        .description = "test package",
        .license = "MIT",
        .url = "https://example.com",
        .installed_at = 0,
        .checksum = "",
    };
}

// ── Тесты ─────────────────────────────────────────────────────────────────────

test "successful install" {
    const allocator = std.testing.allocator;

    const pkg_path = try makeTmpDir(allocator, "test_pkg_success");
    const repo_path = try makeTmpDir(allocator, "test_repo_success");
    const root_path = try makeTmpDir(allocator, "test_root_success");
    const db_path = try makeTmpDir(allocator, "test_db_success");
    defer allocator.free(pkg_path);
    defer allocator.free(repo_path);
    defer allocator.free(root_path);
    defer allocator.free(db_path);
    defer std.fs.deleteTreeAbsolute(pkg_path) catch {};
    defer std.fs.deleteTreeAbsolute(repo_path) catch {};
    defer std.fs.deleteTreeAbsolute(root_path) catch {};
    defer std.fs.deleteTreeAbsolute(db_path) catch {};

    // Создаём структуру пакета
    const bin_path = try std.fs.path.join(allocator, &.{ pkg_path, "usr/bin/foo" });
    defer allocator.free(bin_path);
    const lib_path = try std.fs.path.join(allocator, &.{ pkg_path, "usr/lib/libfoo.so.1" });
    defer allocator.free(lib_path);

    try makeFile(bin_path, "#!/bin/sh\necho foo");
    try makeFile(lib_path, "ELF");

    try installer.install(.{
        .meta = testMeta("foo"),
        .root_path = root_path,
        .repo_path = repo_path,
        .package_path = pkg_path,
        .db_path = db_path,
        .max_retries = 3,
    }, allocator);

    // Проверяем что файлы появились в repo
    const repo_bin = try std.fs.path.join(allocator, &.{ repo_path, "usr/bin/foo" });
    defer allocator.free(repo_bin);
    try std.fs.accessAbsolute(repo_bin, .{});

    // Проверяем что хардлинки появились в root
    const root_bin = try std.fs.path.join(allocator, &.{ root_path, "usr/bin/foo" });
    defer allocator.free(root_bin);
    try std.fs.accessAbsolute(root_bin, .{});

    // Проверяем что пакет появился в БД
    const meta = try db.getMeta(db_path, "foo", allocator);
    defer {
        allocator.free(meta.name);
        allocator.free(meta.version);
        allocator.free(meta.author);
        allocator.free(meta.description);
        allocator.free(meta.license);
        allocator.free(meta.url);
        allocator.free(meta.checksum);
    }
    try std.testing.expectEqualStrings("foo", meta.name);
    try std.testing.expectEqualStrings("1.0.0", meta.version);
}

test "invalid package path" {
    const allocator = std.testing.allocator;

    const repo_path = try makeTmpDir(allocator, "test_repo_invalid");
    const root_path = try makeTmpDir(allocator, "test_root_invalid");
    const db_path = try makeTmpDir(allocator, "test_db_invalid");
    defer allocator.free(repo_path);
    defer allocator.free(root_path);
    defer allocator.free(db_path);
    defer std.fs.deleteTreeAbsolute(repo_path) catch {};
    defer std.fs.deleteTreeAbsolute(root_path) catch {};
    defer std.fs.deleteTreeAbsolute(db_path) catch {};

    // package_path не существует — stateVerifying должен вернуть ошибку
    const result = installer.install(.{
        .meta = testMeta("bar"),
        .root_path = root_path,
        .repo_path = repo_path,
        .package_path = "/tmp/this_does_not_exist_at_all",
        .db_path = db_path,
        .max_retries = 2,
    }, allocator);

    try std.testing.expectError(error.FileNotFound, result);
}

test "retry exhausted" {
    const allocator = std.testing.allocator;

    const pkg_path = try makeTmpDir(allocator, "test_pkg_retry");
    const root_path = try makeTmpDir(allocator, "test_root_retry");
    const db_path = try makeTmpDir(allocator, "test_db_retry");
    defer allocator.free(pkg_path);
    defer allocator.free(root_path);
    defer allocator.free(db_path);
    defer std.fs.deleteTreeAbsolute(pkg_path) catch {};
    defer std.fs.deleteTreeAbsolute(root_path) catch {};
    defer std.fs.deleteTreeAbsolute(db_path) catch {};

    // Создаём файл в пакете
    const bin_path = try std.fs.path.join(allocator, &.{ pkg_path, "usr/bin/baz" });
    defer allocator.free(bin_path);
    try makeFile(bin_path, "binary");

    // repo_path не существует — copying будет падать до исчерпания retry
    const result = installer.install(.{
        .meta = testMeta("baz"),
        .root_path = root_path,
        .repo_path = "/tmp/repo_that_does_not_exist",
        .package_path = pkg_path,
        .db_path = db_path,
        .max_retries = 2,
    }, allocator);

    try std.testing.expectError(error.FileNotFound, result);
}

test "reinstall same package" {
    const allocator = std.testing.allocator;

    const pkg_path = try makeTmpDir(allocator, "test_pkg_reinstall");
    const repo_path = try makeTmpDir(allocator, "test_repo_reinstall");
    const root_path = try makeTmpDir(allocator, "test_root_reinstall");
    const db_path = try makeTmpDir(allocator, "test_db_reinstall");
    defer allocator.free(pkg_path);
    defer allocator.free(repo_path);
    defer allocator.free(root_path);
    defer allocator.free(db_path);
    defer std.fs.deleteTreeAbsolute(pkg_path) catch {};
    defer std.fs.deleteTreeAbsolute(repo_path) catch {};
    defer std.fs.deleteTreeAbsolute(root_path) catch {};
    defer std.fs.deleteTreeAbsolute(db_path) catch {};

    const bin_path = try std.fs.path.join(allocator, &.{ pkg_path, "usr/bin/qux" });
    defer allocator.free(bin_path);
    try makeFile(bin_path, "binary");

    const request = InstallRequest{
        .meta = testMeta("qux"),
        .root_path = root_path,
        .repo_path = repo_path,
        .package_path = pkg_path,
        .db_path = db_path,
        .max_retries = 3,
    };

    // Первая установка
    try installer.install(request, allocator);

    // Повторная установка — не должна падать
    try installer.install(request, allocator);

    // В БД должна быть одна запись
    const names = try db.listPackages(db_path, allocator);
    defer {
        for (names) |n| allocator.free(n);
        allocator.free(names);
    }
    try std.testing.expectEqual(@as(usize, 1), names.len);
}

test "empty package" {
    const allocator = std.testing.allocator;

    const pkg_path = try makeTmpDir(allocator, "test_pkg_empty");
    const repo_path = try makeTmpDir(allocator, "test_repo_empty");
    const root_path = try makeTmpDir(allocator, "test_root_empty");
    const db_path = try makeTmpDir(allocator, "test_db_empty");
    defer allocator.free(pkg_path);
    defer allocator.free(repo_path);
    defer allocator.free(root_path);
    defer allocator.free(db_path);
    defer std.fs.deleteTreeAbsolute(pkg_path) catch {};
    defer std.fs.deleteTreeAbsolute(repo_path) catch {};
    defer std.fs.deleteTreeAbsolute(root_path) catch {};
    defer std.fs.deleteTreeAbsolute(db_path) catch {};

    // Пустая директория пакета — должно пройти без ошибок
    try installer.install(.{
        .meta = testMeta("empty"),
        .root_path = root_path,
        .repo_path = repo_path,
        .package_path = pkg_path,
        .db_path = db_path,
        .max_retries = 3,
    }, allocator);

    // Пакет должен быть зарегистрирован в БД даже без файлов
    const meta = try db.getMeta(db_path, "empty", allocator);
    defer {
        allocator.free(meta.name);
        allocator.free(meta.version);
        allocator.free(meta.author);
        allocator.free(meta.description);
        allocator.free(meta.license);
        allocator.free(meta.url);
        allocator.free(meta.checksum);
    }
    try std.testing.expectEqualStrings("empty", meta.name);
}
