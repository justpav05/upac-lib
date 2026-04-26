// ── Imports ─────────────────────────────────────────────────────────────────────
const std = @import("std");

const types = @import("upac-ffi");
const PackageMeta = types.PackageMeta;

// ── Meta format ─────────────────────────────────────────────────────────────
// <pkg_checksum>.meta:
//   name value
//   version value
//   author value
//   description value
//   license value
//   url value
//   installed_at 1234567890
//   checksum value
//
// <pkg_checksum>.files:
//   /usr/bin/foo deadbeef1234...
//   /usr/lib/libbar.so a3f9b1c2...

// ── Errors ────────────────────────────────────────────────────────────────────
pub const DatabaseError = error{
    PackageNotFound,
    MalformedMeta,
    MalformedFiles,
    AllocZFailed,
    WriteError,
};

const FieldEntry = struct {
    key: []const u8,
    field: *[]const u8,
};

inline fn check(value: anytype, comptime err: DatabaseError) DatabaseError!@typeInfo(@TypeOf(value)).error_union.payload {
    return value catch err;
}

inline fn unwrap(value: anytype, comptime err: DatabaseError) DatabaseError!@typeInfo(@TypeOf(value)).optional.child {
    return value orelse err;
}

// ── FileMap ───────────────────────────────────────────────────────────────────
pub const FileMap = std.StringHashMap([]const u8);

// It iterates over the `FileMap` hash map, freeing the memory allocated for each entry (path and checksum), and subsequently deinitializes the map itself
pub fn freeFileMap(file_map: *FileMap, allocator: std.mem.Allocator) void {
    var file_map_iter = file_map.iterator();

    while (file_map_iter.next()) |entry| {
        allocator.free(entry.key_ptr.*);
        allocator.free(entry.value_ptr.*);
    }

    file_map.deinit();
}

pub fn freePackageMeta(meta: PackageMeta, allocator: std.mem.Allocator) void {
    allocator.free(meta.name);
    allocator.free(meta.version);
    allocator.free(meta.architecture);
    allocator.free(meta.author);
    allocator.free(meta.description);
    allocator.free(meta.license);
    allocator.free(meta.url);
    allocator.free(meta.packager);
    allocator.free(meta.checksum);
}

// ── Public API ─────────────────────────────────────────────────────────────
// A high-level function that sequentially writes the package's metadata and file list to the database
pub fn writePackage(database_path: []const u8, package_checksum: []const u8, package_meta: PackageMeta, files: FileMap, allocator: std.mem.Allocator) DatabaseError!void {
    try writeMeta(database_path, package_checksum, package_meta, allocator);
    try writeFiles(database_path, package_checksum, files, allocator);
}

// Constructs the path to the .meta file, reads its contents into memory, and passes them to the parser to obtain the PackageMeta structure
pub fn readMeta(database_path: []const u8, package_checksum: []const u8, allocator: std.mem.Allocator) DatabaseError!PackageMeta {
    const package_meta_path = try metaPath(database_path, package_checksum, allocator);
    defer allocator.free(package_meta_path);

    const package_meta_content = blk: {
        const meta_file = try check(std.fs.openFileAbsolute(package_meta_path, .{}), DatabaseError.PackageNotFound);
        defer meta_file.close();
        break :blk try check(meta_file.readToEndAlloc(allocator, 1024 * 1024), DatabaseError.PackageNotFound);
    };
    defer allocator.free(package_meta_content);

    return parseMeta(package_meta_content, allocator);
}

// Constructs the path to the .files file, reads its contents into memory, and passes them to the parser to obtain the FileMap structure
pub fn readFiles(database_path: []const u8, package_checksum: []const u8, allocator: std.mem.Allocator) DatabaseError!FileMap {
    const package_files_path = try filesPath(database_path, package_checksum, allocator);
    defer allocator.free(package_files_path);

    const package_files_file = try check(std.fs.openFileAbsolute(package_files_path, .{}), DatabaseError.PackageNotFound);
    defer package_files_file.close();

    const package_files_content = try check(package_files_file.readToEndAlloc(allocator, 16 * 1024 * 1024), DatabaseError.PackageNotFound);
    defer allocator.free(package_files_content);

    return parseFiles(package_files_content, allocator);
}

// ── Write meta file ────────────────────────────────────────────────────────────────────
// Formats the package data (name, version, author, etc.) into a text format and writes it to a file at the absolute path
// ── Write meta file ────────────────────────────────────────────────────────────────────
// Formats the package data (name, version, author, etc.) into a text format and writes it to a file at the absolute path
fn writeMeta(temp_path: []const u8, package_checksum: []const u8, package_meta: PackageMeta, allocator: std.mem.Allocator) DatabaseError!void {
    const package_meta_path = try check(metaPath(temp_path, package_checksum, allocator), DatabaseError.WriteError);
    defer allocator.free(package_meta_path);

    const package_meta_file = try check(std.fs.createFileAbsolute(package_meta_path, .{}), DatabaseError.WriteError);
    defer package_meta_file.close();

    var write_buf: [1024]u8 = undefined;
    var meta_writer = package_meta_file.writer(&write_buf);
    const writer = &meta_writer.interface;

    inline for (std.meta.fields(PackageMeta)) |field| {
        const val = @field(package_meta, field.name);
        const fmt = comptime if (field.type == []const u8) "s" else "d";
        try check(writer.print("{s} {" ++ fmt ++ "}\n", .{ field.name, val }), DatabaseError.WriteError);
    }

    try check(writer.flush(), DatabaseError.WriteError);
}

// ── Write file about package files ────────────────────────────────────────────────────────────────────
// Writes "file path — checksum" pairs from a hash map to the corresponding database file
fn writeFiles(temp_path: []const u8, package_checksum: []const u8, file_map: FileMap, allocator: std.mem.Allocator) DatabaseError!void {
    const package_files_path = try check(filesPath(temp_path, package_checksum, allocator), DatabaseError.WriteError);
    defer allocator.free(package_files_path);

    const package_files_file = try check(std.fs.createFileAbsolute(package_files_path, .{}), DatabaseError.WriteError);
    defer package_files_file.close();

    var write_buf: [4096]u8 = undefined;
    var file_writer = package_files_file.writer(&write_buf);
    const writer = &file_writer.interface;

    var package_files_iter = file_map.iterator();
    while (package_files_iter.next()) |package_entry| {
        try check(writer.print("{s} {s}\n", .{ package_entry.key_ptr.*, package_entry.value_ptr.* }), DatabaseError.WriteError);
    }

    try check(writer.flush(), DatabaseError.WriteError);
}

// ── Parsing meta file ───────────────────────────────────────────────────────────────────
// Parses the contents of a meta-file line by line, separating keys and values by whitespace and populating the PackageMeta structure
fn parseMeta(content: []const u8, allocator: std.mem.Allocator) DatabaseError!PackageMeta {
    var package_meta = PackageMeta{
        .name = &[_]u8{},
        .version = &[_]u8{},
        .size = 0,
        .architecture = &[_]u8{},
        .author = &[_]u8{},
        .description = &[_]u8{},
        .license = &[_]u8{},
        .url = &[_]u8{},
        .packager = &[_]u8{},
        .installed_at = 0,
        .checksum = &[_]u8{},
    };

    var split_content_iterator = std.mem.splitScalar(u8, content, '\n');
    while (split_content_iterator.next()) |content_line| {
        const trimmed_content_line = std.mem.trim(u8, content_line, " \t\r");
        if (trimmed_content_line.len == 0) continue;

        const separator_index = try unwrap(std.mem.indexOfScalar(u8, trimmed_content_line, ' '), DatabaseError.MalformedFiles);

        const key = trimmed_content_line[0..separator_index];
        const value = std.mem.trim(u8, trimmed_content_line[separator_index + 1 ..], " \t");

        var installed_at_seen = false;

        const fields = [_]FieldEntry{
            .{ .key = "name", .field = &package_meta.name },
            .{ .key = "version", .field = &package_meta.version },
            .{ .key = "architecture", .field = &package_meta.architecture },
            .{ .key = "author", .field = &package_meta.author },
            .{ .key = "description", .field = &package_meta.description },
            .{ .key = "license", .field = &package_meta.license },
            .{ .key = "url", .field = &package_meta.url },
            .{ .key = "packager", .field = &package_meta.packager },
            .{ .key = "checksum", .field = &package_meta.checksum },
        };

        for (fields) |entry| {
            if (!std.mem.eql(u8, key, entry.key)) continue;
            if (entry.field.len > 0) return DatabaseError.MalformedMeta;
            entry.field.* = try check(allocator.dupe(u8, value), DatabaseError.MalformedMeta);
            break;
        } else if (std.mem.eql(u8, key, "size")) {
            if (package_meta.size > 0) return DatabaseError.MalformedMeta;
            package_meta.size = std.fmt.parseInt(usize, value, 10) catch return DatabaseError.MalformedMeta;
        } else if (std.mem.eql(u8, key, "installed_at")) {
            if (installed_at_seen) return DatabaseError.MalformedMeta;
            installed_at_seen = true;
            package_meta.installed_at = std.fmt.parseInt(i64, value, 10) catch 0;
        }
    }

    return package_meta;
}

// ── Parsing file about package files ────────────────────────────────────────────────────────────────────
// Parses the contents of a file list, extracting file paths and their hashes to populate the FileMap
fn parseFiles(content: []const u8, allocator: std.mem.Allocator) DatabaseError!FileMap {
    var file_map = FileMap.init(allocator);
    errdefer freeFileMap(&file_map, allocator);

    var split_content_iterator = std.mem.splitScalar(u8, content, '\n');
    while (split_content_iterator.next()) |content_line| {
        const trimmed_content_line = std.mem.trim(u8, content_line, " \t\r");
        if (trimmed_content_line.len == 0) continue;

        const separator_index = try unwrap(std.mem.indexOfScalar(u8, trimmed_content_line, ' '), DatabaseError.MalformedFiles);

        const file_path = std.mem.trim(u8, trimmed_content_line[0..separator_index], " \t");
        const file_checksum = std.mem.trim(u8, trimmed_content_line[separator_index + 1 ..], " \t");

        if (file_path.len == 0 or file_checksum.len == 0) return DatabaseError.MalformedFiles;

        const file_path_dupe = try check(allocator.dupe(u8, file_path), DatabaseError.AllocZFailed);
        const file_checksum_dupe = try check(allocator.dupe(u8, file_checksum), DatabaseError.AllocZFailed);

        try check(file_map.put(file_path_dupe, file_checksum_dupe), DatabaseError.AllocZFailed);
    }

    return file_map;
}

// ── Path helpers ──────────────────────────────────────────────────────────────
// A helper function for generating file path strings for .meta files based on a package checksum
fn metaPath(temp_path: []const u8, package_checksum: []const u8, allocator: std.mem.Allocator) DatabaseError![]const u8 {
    var package_buf: [267]u8 = undefined;
    const filename = try check(std.fmt.bufPrint(&package_buf, "{s}.meta", .{package_checksum}), DatabaseError.AllocZFailed);
    return try check(std.fs.path.join(allocator, &.{ temp_path, filename }), DatabaseError.AllocZFailed);
}

fn filesPath(temp_path: []const u8, package_checksum: []const u8, allocator: std.mem.Allocator) DatabaseError![]const u8 {
    var package_buf: [267]u8 = undefined;
    const filename = try check(std.fmt.bufPrint(&package_buf, "{s}.files", .{package_checksum}), DatabaseError.AllocZFailed);
    return try check(std.fs.path.join(allocator, &.{ temp_path, filename }), DatabaseError.AllocZFailed);
}
