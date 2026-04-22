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
    WriteError,
};

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
pub fn writePackage(database_path: []const u8, package_checksum: []const u8, package_meta: PackageMeta, files: FileMap, allocator: std.mem.Allocator) !void {
    try writeMeta(database_path, package_checksum, package_meta, allocator);
    try writeFiles(database_path, package_checksum, files, allocator);
}

// Constructs the path to the .meta file, reads its contents into memory, and passes them to the parser to obtain the PackageMeta structure
pub fn readMeta(database_path: []const u8, package_checksum: []const u8, allocator: std.mem.Allocator) !PackageMeta {
    const package_meta_path = try metaPath(database_path, package_checksum, allocator);
    defer allocator.free(package_meta_path);

    const package_meta_content = blk: {
        const meta_file = std.fs.openFileAbsolute(package_meta_path, .{}) catch
            return DatabaseError.PackageNotFound;
        defer meta_file.close();
        break :blk meta_file.readToEndAlloc(allocator, 1024 * 1024) catch
            return DatabaseError.PackageNotFound;
    };
    defer allocator.free(package_meta_content);

    return parseMeta(package_meta_content, allocator);
}

// Constructs the path to the .files file, reads its contents into memory, and passes them to the parser to obtain the FileMap structure
pub fn readFiles(database_path: []const u8, package_checksum: []const u8, allocator: std.mem.Allocator) !FileMap {
    const package_files_path = try filesPath(database_path, package_checksum, allocator);
    defer allocator.free(package_files_path);

    const package_files_file = std.fs.openFileAbsolute(package_files_path, .{}) catch return DatabaseError.PackageNotFound;
    defer package_files_file.close();

    const package_files_content = try package_files_file.readToEndAlloc(allocator, 16 * 1024 * 1024);
    defer allocator.free(package_files_content);

    return parseFiles(package_files_content, allocator);
}

// ── Write meta file ────────────────────────────────────────────────────────────────────
// Formats the package data (name, version, author, etc.) into a text format and writes it to a file at the absolute path
fn writeMeta(temp_path: []const u8, package_checksum: []const u8, package_meta: PackageMeta, allocator: std.mem.Allocator) !void {
    const package_meta_path = try metaPath(temp_path, package_checksum, allocator);
    defer allocator.free(package_meta_path);

    const package_meta_file = std.fs.createFileAbsolute(package_meta_path, .{}) catch return DatabaseError.WriteError;
    defer package_meta_file.close();

    const package_meta_writer = package_meta_file.writer();

    package_meta_writer.print("name {s}\n", .{package_meta.name}) catch return DatabaseError.WriteError;
    package_meta_writer.print("version {s}\n", .{package_meta.version}) catch return DatabaseError.WriteError;
    package_meta_writer.print("author {s}\n", .{package_meta.author}) catch return DatabaseError.WriteError;
    package_meta_writer.print("size {d}\n", .{package_meta.size}) catch return DatabaseError.WriteError;
    package_meta_writer.print("architecture {s}\n", .{package_meta.architecture}) catch return DatabaseError.WriteError;
    package_meta_writer.print("description {s}\n", .{package_meta.description}) catch return DatabaseError.WriteError;
    package_meta_writer.print("license {s}\n", .{package_meta.license}) catch return DatabaseError.WriteError;
    package_meta_writer.print("url {s}\n", .{package_meta.url}) catch return DatabaseError.WriteError;
    package_meta_writer.print("packager {s}\n", .{package_meta.packager}) catch return DatabaseError.WriteError;
    package_meta_writer.print("installed_at {d}\n", .{package_meta.installed_at}) catch return DatabaseError.WriteError;
    package_meta_writer.print("checksum {s}\n", .{package_meta.checksum}) catch return DatabaseError.WriteError;
}

// ── Write file about package files ────────────────────────────────────────────────────────────────────
// Writes "file path — checksum" pairs from a hash map to the corresponding database file
fn writeFiles(temp_path: []const u8, package_checksum: []const u8, file_map: FileMap, allocator: std.mem.Allocator) !void {
    const package_files_path = try filesPath(temp_path, package_checksum, allocator);
    defer allocator.free(package_files_path);

    const package_files_file = std.fs.createFileAbsolute(package_files_path, .{}) catch return DatabaseError.WriteError;
    defer package_files_file.close();

    const package_file_writer = package_files_file.writer();
    var package_files_iter = file_map.iterator();
    while (package_files_iter.next()) |package_entry| {
        package_file_writer.print("{s} {s}\n", .{ package_entry.key_ptr.*, package_entry.value_ptr.* }) catch return DatabaseError.WriteError;
    }
}

// ── Parsing meta file ───────────────────────────────────────────────────────────────────
// Parses the contents of a meta-file line by line, separating keys and values by whitespace and populating the PackageMeta structure
fn parseMeta(content: []const u8, allocator: std.mem.Allocator) !PackageMeta {
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

        const separator_index = std.mem.indexOfScalar(u8, trimmed_content_line, ' ') orelse return DatabaseError.MalformedMeta;

        const key = trimmed_content_line[0..separator_index];
        const value = std.mem.trim(u8, trimmed_content_line[separator_index + 1 ..], " \t");

        var installed_at_seen = false;

        if (std.mem.eql(u8, key, "name")) {
            if (package_meta.name.len > 0) return DatabaseError.MalformedMeta;
            package_meta.name = try allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "version")) {
            if (package_meta.version.len > 0) return DatabaseError.MalformedMeta;
            package_meta.version = try allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "size")) {
            if (package_meta.size > 0) return DatabaseError.MalformedMeta;
            package_meta.size = std.fmt.parseInt(usize, value, 10) catch return DatabaseError.MalformedMeta;
        } else if (std.mem.eql(u8, key, "architecture")) {
            if (package_meta.architecture.len > 0) return DatabaseError.MalformedMeta;
            package_meta.architecture = try allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "author")) {
            if (package_meta.author.len > 0) return DatabaseError.MalformedMeta;
            package_meta.author = try allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "description")) {
            if (package_meta.description.len > 0) return DatabaseError.MalformedMeta;
            package_meta.description = try allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "license")) {
            if (package_meta.license.len > 0) return DatabaseError.MalformedMeta;
            package_meta.license = try allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "url")) {
            if (package_meta.url.len > 0) return DatabaseError.MalformedMeta;
            package_meta.url = try allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "packager")) {
            if (package_meta.packager.len > 0) return DatabaseError.MalformedMeta;
            package_meta.packager = try allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "installed_at")) {
            if (installed_at_seen) return DatabaseError.MalformedMeta;
            installed_at_seen = true;
            package_meta.installed_at = std.fmt.parseInt(i64, value, 10) catch 0;
        } else if (std.mem.eql(u8, key, "checksum")) {
            if (package_meta.checksum.len > 0) return DatabaseError.MalformedMeta;
            package_meta.checksum = try allocator.dupe(u8, value);
        }
    }

    if (package_meta.name.len == 0) return DatabaseError.MalformedMeta;
    return package_meta;
}

// ── Parsing file about package files ────────────────────────────────────────────────────────────────────
// Parses the contents of a file list, extracting file paths and their hashes to populate the FileMap
fn parseFiles(content: []const u8, allocator: std.mem.Allocator) !FileMap {
    var file_map = FileMap.init(allocator);
    errdefer freeFileMap(&file_map, allocator);

    var split_content_iterator = std.mem.splitScalar(u8, content, '\n');
    while (split_content_iterator.next()) |content_line| {
        const trimmed_content_line = std.mem.trim(u8, content_line, " \t\r");
        if (trimmed_content_line.len == 0) continue;

        const separator_index = std.mem.indexOfScalar(u8, trimmed_content_line, ' ') orelse return DatabaseError.MalformedFiles;

        const file_path = std.mem.trim(u8, trimmed_content_line[0..separator_index], " \t");
        const file_checksum = std.mem.trim(u8, trimmed_content_line[separator_index + 1 ..], " \t");

        if (file_path.len == 0 or file_checksum.len == 0)
            return DatabaseError.MalformedFiles;

        try file_map.put(try allocator.dupe(u8, file_path), try allocator.dupe(u8, file_checksum));
    }

    return file_map;
}

// ── Path helpers ──────────────────────────────────────────────────────────────
// A helper function for generating file path strings for .meta files based on a package checksum
fn metaPath(temp_path: []const u8, package_checksum: []const u8, allocator: std.mem.Allocator) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}/{s}.meta", .{ temp_path, package_checksum });
}

// A helper function for generating file path strings for .files files based on a package checksum
fn filesPath(temp_path: []const u8, package_checksum: []const u8, allocator: std.mem.Allocator) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}/{s}.files", .{ temp_path, package_checksum });
}
