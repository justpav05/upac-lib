const std = @import("std");

const fsm = @import("machine.zig");
const states = @import("states.zig");

// ── Публичные типы ────────────────────────────────────────────────────────────
pub const PackageMeta = struct {
    name: []const u8,
    version: []const u8,
    author: []const u8,
    description: []const u8,
    license: []const u8,
    url: []const u8,
    installed_at: i64,
    checksum: []const u8,
};

pub const PackageFiles = struct {
    name: []const u8,
    paths: []const []const u8,
};

// ── Публичное API ─────────────────────────────────────────────────────────────
/// Добавить или обновить пакет в базе данных.
pub fn addPackage(dir_path: []const u8, package_meta: PackageMeta, package_files: PackageFiles, allocator: std.mem.Allocator) !void {
    _ = try fsm.runMachine(dir_path, allocator, .{ .add = .{ .meta = package_meta, .files = package_files } });
}

/// Удалить пакет из базы данных.
pub fn removePackage(dir_path: []const u8, package_name: []const u8, allocator: std.mem.Allocator) !void {
    _ = try fsm.runMachine(dir_path, allocator, .{ .remove = .{ .name = package_name } });
}

/// Получить метаданные пакета. Вызывающий освобождает все поля PackageMeta.
pub fn getMeta(dir_path: []const u8, package_name: []const u8, allocator: std.mem.Allocator) !PackageMeta {
    const result = try fsm.runMachine(dir_path, allocator, .{ .read_meta = .{ .name = package_name } });
    return result.?.read_meta;
}

/// Получить список файлов пакета. Вызывающий освобождает PackageFiles.paths.
pub fn getFiles(dir_path: []const u8, package_name: []const u8, allocator: std.mem.Allocator) !PackageFiles {
    const result = try fsm.runMachine(dir_path, allocator, .{ .read_files = .{ .name = package_name } });
    return result.?.read_files;
}

/// Получить список имён всех установленных пакетов.
/// Вызывающий освобождает каждую строку и слайс.
pub fn listPackages(dir_path: []const u8, allocator: std.mem.Allocator) ![][]const u8 {
    const result = try fsm.runMachine(dir_path, allocator, .{ .list = .{} });
    return result.?.list;
}
