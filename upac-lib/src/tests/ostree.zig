const std = @import("std");
const ostree = @import("upac-ostree");
const db = @import("upac-database");

const PackageMeta = db.PackageMeta;

// ── Хелперы ───────────────────────────────────────────────────────────────────

const c = @cImport({
    @cInclude("ostree.h");
    @cInclude("glib.h");
    @cInclude("gio/gio.h");
});

fn testMeta(name: []const u8, version: []const u8) PackageMeta {
    return PackageMeta{
        .name = name,
        .version = version,
        .author = "test",
        .description = "test package",
        .license = "MIT",
        .url = "https://example.com",
        .installed_at = 0,
        .checksum = "",
    };
}

/// Создаёт временный OStree репозиторий.
/// Вызывающий удаляет через std.fs.deleteTreeAbsolute.
fn initTmpRepo(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    const repo_path = try std.fs.path.join(allocator, &.{ "/tmp", name });

    std.fs.makeDirAbsolute(repo_path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    const repo_path_c = try std.fmt.allocPrintZ(allocator, "{s}", .{repo_path});
    defer allocator.free(repo_path_c);

    const file = c.g_file_new_for_path(repo_path_c.ptr);
    defer c.g_object_unref(file);

    const repo = c.ostree_repo_new(file);
    defer c.g_object_unref(repo);

    var err: ?*c.GError = null;
    if (c.ostree_repo_create(repo, c.OSTREE_REPO_MODE_ARCHIVE, null, &err) == 0) {
        if (err) |e| c.g_error_free(e);
        return error.RepoCreateFailed;
    }

    return repo_path;
}

/// Создаёт временную директорию с файлом внутри.
fn initTmpContent(allocator: std.mem.Allocator, name: []const u8, filename: []const u8, content: []const u8) ![]const u8 {
    const path = try std.fs.path.join(allocator, &.{ "/tmp", name });
    std.fs.makeDirAbsolute(path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    const file_path = try std.fs.path.join(allocator, &.{ path, filename });
    defer allocator.free(file_path);
    try std.fs.cwd().writeFile(.{ .sub_path = file_path, .data = content });

    return path;
}

// ── Тесты ─────────────────────────────────────────────────────────────────────

test "commit single package" {
    const allocator = std.testing.allocator;

    const repo_path = try initTmpRepo(allocator, "test_ostree_commit_repo");
    const content_path = try initTmpContent(allocator, "test_ostree_commit_content", "usr/bin/foo", "binary");
    const db_path = try std.fs.path.join(allocator, &.{ "/tmp", "test_ostree_commit_db" });
    std.fs.makeDirAbsolute(db_path) catch {};

    defer allocator.free(repo_path);
    defer allocator.free(content_path);
    defer allocator.free(db_path);
    defer std.fs.deleteTreeAbsolute(repo_path) catch {};
    defer std.fs.deleteTreeAbsolute(content_path) catch {};
    defer std.fs.deleteTreeAbsolute(db_path) catch {};

    const packages = [_]PackageMeta{testMeta("foo", "1.0.0")};

    try ostree.commit(.{
        .repo_path = repo_path,
        .content_path = content_path,
        .branch = "packages",
        .operation = "install",
        .packages = &packages,
        .db_path = db_path,
    }, allocator);
}

test "commit multiple packages" {
    const allocator = std.testing.allocator;

    const repo_path = try initTmpRepo(allocator, "test_ostree_multi_repo");
    const content_path = try initTmpContent(allocator, "test_ostree_multi_content", "usr/bin/bar", "binary");
    const db_path = try std.fs.path.join(allocator, &.{ "/tmp", "test_ostree_multi_db" });
    std.fs.makeDirAbsolute(db_path) catch {};

    defer allocator.free(repo_path);
    defer allocator.free(content_path);
    defer allocator.free(db_path);
    defer std.fs.deleteTreeAbsolute(repo_path) catch {};
    defer std.fs.deleteTreeAbsolute(content_path) catch {};
    defer std.fs.deleteTreeAbsolute(db_path) catch {};

    const packages = [_]PackageMeta{
        testMeta("foo", "1.0.0"),
        testMeta("bar", "2.1.0"),
        testMeta("baz", "0.5.0"),
    };

    try ostree.commit(.{
        .repo_path = repo_path,
        .content_path = content_path,
        .branch = "packages",
        .operation = "install",
        .packages = &packages,
        .db_path = db_path,
    }, allocator);
}

test "diff between two commits" {
    const allocator = std.testing.allocator;

    const repo_path = try initTmpRepo(allocator, "test_ostree_diff_repo");
    const content_path = try initTmpContent(allocator, "test_ostree_diff_content", "usr/bin/foo", "v1");
    const db_path = try std.fs.path.join(allocator, &.{ "/tmp", "test_ostree_diff_db" });
    std.fs.makeDirAbsolute(db_path) catch {};

    defer allocator.free(repo_path);
    defer allocator.free(content_path);
    defer allocator.free(db_path);
    defer std.fs.deleteTreeAbsolute(repo_path) catch {};
    defer std.fs.deleteTreeAbsolute(content_path) catch {};
    defer std.fs.deleteTreeAbsolute(db_path) catch {};

    // Первый коммит
    const pkgs_v1 = [_]PackageMeta{testMeta("foo", "1.0.0")};
    try ostree.commit(.{
        .repo_path = repo_path,
        .content_path = content_path,
        .branch = "packages",
        .operation = "install",
        .packages = &pkgs_v1,
        .db_path = db_path,
    }, allocator);

    // Изменяем содержимое
    const file_path = try std.fs.path.join(allocator, &.{ content_path, "usr/bin/foo" });
    defer allocator.free(file_path);
    try std.fs.cwd().writeFile(.{ .sub_path = file_path, .data = "v2" });

    // Добавляем новый файл
    const new_file = try std.fs.path.join(allocator, &.{ content_path, "usr/bin/bar" });
    defer allocator.free(new_file);
    try std.fs.cwd().writeFile(.{ .sub_path = new_file, .data = "binary" });

    // Второй коммит
    const pkgs_v2 = [_]PackageMeta{ testMeta("foo", "2.0.0"), testMeta("bar", "1.0.0") };
    try ostree.commit(.{
        .repo_path = repo_path,
        .content_path = content_path,
        .branch = "packages",
        .operation = "update",
        .packages = &pkgs_v2,
        .db_path = db_path,
    }, allocator);

    // Diff между коммитами
    const entries = try ostree.diff(repo_path, "packages^", "packages", allocator);
    defer {
        for (entries) |e| allocator.free(e.path);
        allocator.free(entries);
    }

    // Должны быть изменения
    try std.testing.expect(entries.len > 0);

    // Проверяем что bar появился как added
    var found_added = false;
    for (entries) |e| {
        if (std.mem.endsWith(u8, e.path, "bar") and e.kind == .added) {
            found_added = true;
        }
    }
    try std.testing.expect(found_added);
}

test "rollback to previous commit" {
    const allocator = std.testing.allocator;

    const repo_path = try initTmpRepo(allocator, "test_ostree_rollback_repo");
    const content_path = try initTmpContent(allocator, "test_ostree_rollback_content", "usr/bin/foo", "v1");
    const db_path = try std.fs.path.join(allocator, &.{ "/tmp", "test_ostree_rollback_db" });
    std.fs.makeDirAbsolute(db_path) catch {};

    defer allocator.free(repo_path);
    defer allocator.free(content_path);
    defer allocator.free(db_path);
    defer std.fs.deleteTreeAbsolute(repo_path) catch {};
    defer std.fs.deleteTreeAbsolute(content_path) catch {};
    defer std.fs.deleteTreeAbsolute(db_path) catch {};

    // Первый коммит
    const pkgs_v1 = [_]PackageMeta{testMeta("foo", "1.0.0")};
    try ostree.commit(.{
        .repo_path = repo_path,
        .content_path = content_path,
        .branch = "packages",
        .operation = "install",
        .packages = &pkgs_v1,
        .db_path = db_path,
    }, allocator);

    // Второй коммит с изменениями
    const file_path = try std.fs.path.join(allocator, &.{ content_path, "usr/bin/foo" });
    defer allocator.free(file_path);
    try std.fs.cwd().writeFile(.{ .sub_path = file_path, .data = "v2 — broken" });

    const pkgs_v2 = [_]PackageMeta{testMeta("foo", "2.0.0")};
    try ostree.commit(.{
        .repo_path = repo_path,
        .content_path = content_path,
        .branch = "packages",
        .operation = "update",
        .packages = &pkgs_v2,
        .db_path = db_path,
    }, allocator);

    // Откатываемся
    try ostree.rollback(repo_path, content_path, "packages", allocator);

    // Проверяем что содержимое вернулось к v1
    const restored = try std.fs.cwd().readFileAlloc(allocator, file_path, 1024);
    defer allocator.free(restored);
    try std.testing.expectEqualStrings("v1", restored);
}

test "rollback with no previous commit returns error" {
    const allocator = std.testing.allocator;

    const repo_path = try initTmpRepo(allocator, "test_ostree_noparent_repo");
    const content_path = try initTmpContent(allocator, "test_ostree_noparent_content", "usr/bin/foo", "v1");
    const db_path = try std.fs.path.join(allocator, &.{ "/tmp", "test_ostree_noparent_db" });
    std.fs.makeDirAbsolute(db_path) catch {};

    defer allocator.free(repo_path);
    defer allocator.free(content_path);
    defer allocator.free(db_path);
    defer std.fs.deleteTreeAbsolute(repo_path) catch {};
    defer std.fs.deleteTreeAbsolute(content_path) catch {};
    defer std.fs.deleteTreeAbsolute(db_path) catch {};

    const pkgs = [_]PackageMeta{testMeta("foo", "1.0.0")};
    try ostree.commit(.{
        .repo_path = repo_path,
        .content_path = content_path,
        .branch = "packages",
        .operation = "install",
        .packages = &pkgs,
        .db_path = db_path,
    }, allocator);

    const result = ostree.rollback(repo_path, content_path, "packages", allocator);
    try std.testing.expectError(ostree.OstreeError.NoPreviousCommit, result);
}
