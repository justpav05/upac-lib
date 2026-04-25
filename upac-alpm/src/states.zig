// ── Imports ─────────────────────────────────────────────────────────────────────
const std = @import("std");
const posix = std.posix;

const backend = @import("backend.zig");
const Machine = backend.BackendMachine;
const PackageMeta = backend.PackageMeta;
const BackendError = backend.BackendError;

const c_libs = @cImport({
    @cInclude("archive.h");
    @cInclude("archive_entry.h");
});

// ── States ─────────────────────────────────────────────────────────────────
// Archive integrity check status: calculating SHA256 and comparing against expected value
pub fn stateVerifying(machine: *Machine) BackendError!void {
    try machine.check(machine.enter(.verifying), BackendError.OutOfMemory);

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var hasher_buf: [4096]u8 = undefined;

    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    var actual: [std.crypto.hash.sha2.Sha256.digest_length * 2]u8 = undefined;

    const package_file = try machine.check(std.fs.openFileAbsoluteZ(machine.request.package_path_c, .{}), BackendError.ReadFailed);
    machine.file = package_file;

    while (true) {
        const index = try machine.check(package_file.read(&hasher_buf), BackendError.ReadFailed);

        if (index == 0) break;
        hasher.update(hasher_buf[0..index]);
    }
    hasher.final(&digest);

    _ = try machine.check(std.fmt.bufPrint(&actual, "{}", .{std.fmt.fmtSliceHexLower(&digest)}), BackendError.ReadFailed);

    if (!std.mem.eql(u8, &actual, machine.request.checksum)) {
        stateFailed(machine);
        return BackendError.ChecksumMismatch;
    }

    return stateExtracting(machine);
}

// Unpacking state: uses libarchive to extract files to the temp directory
fn stateExtracting(machine: *Machine) BackendError!void {
    try machine.check(machine.enter(.extracting), BackendError.OutOfMemory);

    var tem_dir_buf: [256]u8 = undefined;
    const timestamp = std.time.milliTimestamp();

    const tepm_dir_name = try machine.check(std.fmt.bufPrintZ(&tem_dir_buf, "upac-installed-{d}", .{timestamp}), BackendError.AllocZFailed);
    const temp_dir_path = try machine.check(std.fs.path.joinZ(machine.allocator, &.{ std.mem.span(machine.request.temp_dir_path_c), tepm_dir_name }), BackendError.AllocZFailed);

    try machine.check(std.fs.makeDirAbsolute(temp_dir_path), BackendError.TempDirFailed);
    machine.temp_path = temp_dir_path;

    const archive_reader = try machine.unwrap(c_libs.archive_read_new(), BackendError.ArchiveOpenFailed);
    defer _ = c_libs.archive_read_free(archive_reader);

    _ = c_libs.archive_read_support_format_tar(archive_reader);
    _ = c_libs.archive_read_support_filter_zstd(archive_reader);
    _ = c_libs.archive_read_support_filter_xz(archive_reader);
    _ = c_libs.archive_read_support_filter_gzip(archive_reader);

    if (c_libs.archive_read_open_filename(archive_reader, machine.request.package_path_c, 16384) != c_libs.ARCHIVE_OK) {
        stateFailed(machine);
        return BackendError.ArchiveOpenFailed;
    }

    const archive_writer = c_libs.archive_write_disk_new() orelse {
        stateFailed(machine);
        return BackendError.ArchiveOpenFailed;
    };
    defer _ = c_libs.archive_write_free(archive_writer);

    _ = c_libs.archive_write_disk_set_options(archive_writer, c_libs.ARCHIVE_EXTRACT_TIME |
        c_libs.ARCHIVE_EXTRACT_PERM |
        c_libs.ARCHIVE_EXTRACT_FFLAGS);
    _ = c_libs.archive_write_disk_set_standard_lookup(archive_writer);

    var buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
    const cwd_path = std.posix.getcwd(&buf) catch {
        stateFailed(machine);
        return BackendError.TempDirFailed;
    };

    var old_dir = try machine.check(std.fs.openDirAbsolute(cwd_path, .{}), BackendError.ReadFailed);
    defer old_dir.close();

    try machine.check(posix.chdir(temp_dir_path), BackendError.OutOfMemory);
    defer old_dir.setAsCwd() catch {};

    while (true) {
        var entry: ?*c_libs.archive_entry = null;
        const result_code = c_libs.archive_read_next_header(archive_reader, &entry);
        if (result_code == c_libs.ARCHIVE_EOF) break;
        if (result_code != c_libs.ARCHIVE_OK) {
            stateFailed(machine);
            return BackendError.ArchiveReadFailed;
        }

        const entry_path = c_libs.archive_entry_pathname(entry.?);
        const is_pkginfo = entry_path != null and std.mem.eql(u8, std.mem.span(entry_path), ".PKGINFO");

        if (is_pkginfo) {
            var pkginfo_buf = std.ArrayList(u8).init(machine.allocator);

            var block: ?*const anyopaque = null;
            var size: usize = 0;
            var offset: i64 = 0;

            while (true) {
                const reader = c_libs.archive_read_data_block(archive_reader, &block, &size, &offset);
                if (reader == c_libs.ARCHIVE_EOF) break;
                if (reader != c_libs.ARCHIVE_OK) {
                    pkginfo_buf.deinit();
                    stateFailed(machine);
                    return BackendError.ArchiveReadFailed;
                }
                if (block) |b| {
                    pkginfo_buf.appendSlice(@as([*]const u8, @ptrCast(b))[0..size]) catch {
                        pkginfo_buf.deinit();
                        stateFailed(machine);
                        return BackendError.OutOfMemory;
                    };
                }
            }

            machine.pkginfo_content = try pkginfo_buf.toOwnedSlice();
            continue;
        }

        if (c_libs.archive_write_header(archive_writer, entry) != c_libs.ARCHIVE_OK) {
            stateFailed(machine);
            return BackendError.ArchiveExtractFailed;
        }

        while (true) {
            var block: ?*const anyopaque = null;
            var size: usize = 0;
            var offset: i64 = 0;

            const rd = c_libs.archive_read_data_block(archive_reader, &block, &size, &offset);
            if (rd == c_libs.ARCHIVE_EOF) break;
            if (rd != c_libs.ARCHIVE_OK) {
                stateFailed(machine);
                return BackendError.ArchiveReadFailed;
            }

            if (c_libs.archive_write_data_block(archive_writer, block, size, offset) != c_libs.ARCHIVE_OK) {
                stateFailed(machine);
                return BackendError.ArchiveExtractFailed;
            }
        }

        if (c_libs.archive_write_finish_entry(archive_writer) != c_libs.ARCHIVE_OK) {
            stateFailed(machine);
            return BackendError.ArchiveExtractFailed;
        }
    }

    return stateReadingMeta(machine);
}

// Parsing status: searching for and parsing the .PKGINFO file to populate package metadata
fn stateReadingMeta(machine: *Machine) BackendError!void {
    machine.enter(.reading_meta) catch {
        stateFailed(machine);
        return BackendError.OutOfMemory;
    };

    const temp_path = try machine.unwrap(machine.temp_path, BackendError.TempDirFailed);

    const pkginfo_path = try std.fs.path.join(machine.allocator, &.{ temp_path, ".PKGINFO" });
    defer machine.allocator.free(pkginfo_path);

    const content = try machine.unwrap(machine.pkginfo_content, BackendError.MetadataNotFound);
    defer {
        machine.allocator.free(content);
        machine.pkginfo_content = null;
    }

    var name: ?[]const u8 = null;
    var version: ?[]const u8 = null;
    var arch: ?[]const u8 = null;
    var description: ?[]const u8 = null;
    var url: ?[]const u8 = null;
    var packager: ?[]const u8 = null;
    var license: ?[]const u8 = null;
    var size: u32 = 0;

    errdefer {
        if (name) |value| machine.allocator.free(value);
        if (version) |value| machine.allocator.free(value);
        if (arch) |value| machine.allocator.free(value);
        if (description) |value| machine.allocator.free(value);
        if (url) |value| machine.allocator.free(value);
        if (packager) |value| machine.allocator.free(value);
        if (license) |value| machine.allocator.free(value);
    }

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const trimmed_line = std.mem.trim(u8, line, " \t\r");
        if (trimmed_line.len == 0 or trimmed_line[0] == '#') continue;

        const separator_index = std.mem.indexOf(u8, trimmed_line, " = ") orelse continue;

        const key = std.mem.trim(u8, trimmed_line[0..separator_index], " \t");
        const value = std.mem.trim(u8, trimmed_line[separator_index + 3 ..], " \t");

        if (std.mem.eql(u8, key, "pkgname")) {
            name = try machine.allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "pkgver")) {
            version = try machine.allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "arch")) {
            arch = try machine.allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "pkgdesc")) {
            description = try machine.allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "url")) {
            url = try machine.allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "packager")) {
            packager = try machine.allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "license")) {
            license = try machine.allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "size")) {
            size = std.fmt.parseInt(u32, value, 10) catch 0;
        }
    }

    if (name == null or version == null) {
        stateFailed(machine);
        return BackendError.InvalidPackage;
    }

    machine.meta = PackageMeta{
        .name = name.?,
        .version = version.?,
        .arch = arch orelse try machine.allocator.dupe(u8, "any"),
        .size = size,
        .author = packager orelse try machine.allocator.dupe(u8, ""),
        .packager = packager orelse try machine.allocator.dupe(u8, ""),
        .description = description orelse try machine.allocator.dupe(u8, ""),
        .license = license orelse try machine.allocator.dupe(u8, ""),
        .url = url orelse try machine.allocator.dupe(u8, ""),
        .installed_at = std.time.timestamp(),
        .checksum = try machine.allocator.dupe(u8, machine.request.checksum),
    };

    const alpm_junk_files = [_][]const u8{ ".BUILDINFO", ".MTREE", ".INSTALL", ".CHANGELOG" };
    for (alpm_junk_files) |filename| {
        const junk_file_path = std.fs.path.join(machine.allocator, &.{ machine.temp_path.?, filename }) catch continue;
        defer machine.allocator.free(junk_file_path);
        std.fs.cwd().deleteFile(junk_file_path) catch {};
    }

    return stateDone(machine);
}

// The final state representing the successful completion of all processing stages
fn stateDone(machine: *Machine) BackendError!void {
    machine.enter(.done) catch {
        stateFailed(machine);
        return BackendError.OutOfMemory;
    };
}

// An error state signaling that the machine failed to reach the required state at a certain stage
pub fn stateFailed(machine: *Machine) void {
    if (machine.temp_path) |path| {
        std.fs.deleteTreeAbsolute(path) catch {};
        machine.allocator.free(path);
        machine.temp_path = null;
    }
    _ = machine.enter(.failed) catch {};
}
