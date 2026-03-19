const std = @import("std");

const fsm = @import("machine.zig");
const states = @import("states.zig");

pub const types = @import("types.zig");
pub const PackageMeta = types.PackageMeta;
pub const PackageFiles = types.PackageFiles;

// ── Публичное API ─────────────────────────────────────────────────────────────

/// Добавить или обновить пакет в базе данных.
pub fn addPackage(
    dir_path: []const u8,
    meta: PackageMeta,
    files: PackageFiles,
    allocator: std.mem.Allocator,
) !void {
    _ = try fsm.runMachine(dir_path, allocator, .{ .add = .{ .meta = meta, .files = files } });
}

/// Удалить пакет из базы данных.
pub fn removePackage(
    dir_path: []const u8,
    name: []const u8,
    allocator: std.mem.Allocator,
) !void {
    _ = try fsm.runMachine(dir_path, allocator, .{ .remove = .{ .name = name } });
}

/// Получить метаданные пакета. Вызывающий освобождает все поля PackageMeta.
pub fn getMeta(
    dir_path: []const u8,
    name: []const u8,
    allocator: std.mem.Allocator,
) !PackageMeta {
    const result = try fsm.runMachine(dir_path, allocator, .{ .read_meta = .{ .name = name } });
    return result.?.read_meta;
}

/// Получить список файлов пакета. Вызывающий освобождает PackageFiles.paths.
pub fn getFiles(
    dir_path: []const u8,
    name: []const u8,
    allocator: std.mem.Allocator,
) !PackageFiles {
    const result = try fsm.runMachine(dir_path, allocator, .{ .read_files = .{ .name = name } });
    return result.?.read_files;
}

/// Получить список имён всех установленных пакетов.
/// Вызывающий освобождает каждую строку и слайс.
pub fn listPackages(
    dir_path: []const u8,
    allocator: std.mem.Allocator,
) ![][]const u8 {
    const result = try fsm.runMachine(dir_path, allocator, .{ .list = .{} });
    return result.?.list;
}
