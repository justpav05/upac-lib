const std = @import("std");
const db = @import("upac-database");

const DB_PATH = "/tmp/pkgdb_test";

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    std.fs.cwd().makePath(DB_PATH) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    std.debug.print("\n=== database test ===\n\n", .{});

    // ── 1. Добавляем пакет ────────────────────────────────────────────────────

    const meta = db.PackageMeta{
        .name = "foo",
        .version = "1.2.3",
        .author = "someone",
        .description = "test package",
        .license = "MIT",
        .url = "https://example.com/foo",
        .installed_at = std.time.timestamp(),
        .checksum = "sha256:deadbeef",
    };
    const files = db.PackageFiles{
        .name = "foo",
        .paths = &.{ "/usr/bin/foo", "/usr/lib/libfoo.so.1" },
    };

    std.debug.print("[1] addPackage 'foo'...\n", .{});
    try db.addPackage(DB_PATH, meta, files, alloc);
    std.debug.print("    ok\n\n", .{});

    // ── 2. Добавляем второй пакет ─────────────────────────────────────────────

    const meta2 = db.PackageMeta{
        .name = "bar",
        .version = "0.1.0-rc1",
        .author = "another",
        .description = "another test package",
        .license = "Apache-2.0",
        .url = "https://example.com/bar",
        .installed_at = std.time.timestamp(),
        .checksum = "sha256:cafebabe",
    };
    const files2 = db.PackageFiles{
        .name = "bar",
        .paths = &.{"/usr/bin/bar"},
    };

    std.debug.print("[2] addPackage 'bar'...\n", .{});
    try db.addPackage(DB_PATH, meta2, files2, alloc);
    std.debug.print("    ok\n\n", .{});

    // ── 3. Список пакетов ─────────────────────────────────────────────────────

    std.debug.print("[3] listPackages...\n", .{});
    const names = try db.listPackages(DB_PATH, alloc);
    defer {
        for (names) |n| alloc.free(n);
        alloc.free(names);
    }
    for (names) |n| std.debug.print("    - {s}\n", .{n});
    std.debug.print("\n", .{});

    // ── 4. Читаем метаданные ──────────────────────────────────────────────────

    std.debug.print("[4] getMeta 'foo'...\n", .{});
    const got_meta = try db.getMeta(DB_PATH, "foo", alloc);
    defer {
        alloc.free(got_meta.name);
        alloc.free(got_meta.version);
        alloc.free(got_meta.author);
        alloc.free(got_meta.description);
        alloc.free(got_meta.license);
        alloc.free(got_meta.url);
        alloc.free(got_meta.checksum);
    }
    std.debug.print("    name:    {s}\n", .{got_meta.name});
    std.debug.print("    version: {s}\n", .{got_meta.version});
    std.debug.print("    author:  {s}\n", .{got_meta.author});
    std.debug.print("    license: {s}\n", .{got_meta.license});
    std.debug.print("\n", .{});

    // ── 5. Читаем файлы ───────────────────────────────────────────────────────

    std.debug.print("[5] getFiles 'foo'...\n", .{});
    const got_files = try db.getFiles(DB_PATH, "foo", alloc);
    defer {
        for (got_files.paths) |p| alloc.free(p);
        alloc.free(got_files.paths);
        alloc.free(got_files.name);
    }
    for (got_files.paths) |p| std.debug.print("    - {s}\n", .{p});
    std.debug.print("\n", .{});

    // ── 6. Удаляем пакет ─────────────────────────────────────────────────────

    std.debug.print("[6] removePackage 'bar'...\n", .{});
    try db.removePackage(DB_PATH, "bar", alloc);
    std.debug.print("    ok\n\n", .{});

    // ── 7. Проверяем что bar удалён из индекса ────────────────────────────────

    std.debug.print("[7] listPackages after remove...\n", .{});
    const names2 = try db.listPackages(DB_PATH, alloc);
    defer {
        for (names2) |n| alloc.free(n);
        alloc.free(names2);
    }
    for (names2) |n| std.debug.print("    - {s}\n", .{n});
    std.debug.print("\n", .{});

    std.debug.print("=== all done ===\n", .{});
}
