// ── Imports ─────────────────────────────────────────────────────────────────────
const backend = @import("backend.zig");
const std = backend.std;
const posix = backend.std.posix;
const c_libs = backend.c_libs;

const Machine = backend.BackendMachine;
const PackageMeta = backend.PackageMeta;
const BackendError = backend.BackendError;

const package_meta_field_map = backend.package_meta_field_map;

// ── States ─────────────────────────────────────────────────────────────────
// Archive integrity check status: calculating SHA256 and comparing against expected value
pub fn stateVerifying(machine: *Machine) BackendError!void {
    try machine.check(machine.enter(.verifying), BackendError.OutOfMemory);

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var hasher_buf: [65536]u8 = undefined;

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

    const file_descriptor = try machine.unwrap(machine.file, BackendError.ArchiveOpenFailed);
    try machine.check(file_descriptor.seekTo(0), BackendError.ArchiveOpenFailed);

    return stateExtracting(machine);
}

// Unpacking state: uses libarchive to extract files to the temp directory
fn stateExtracting(machine: *Machine) BackendError!void {
    try machine.check(machine.enter(.extracting), BackendError.OutOfMemory);

    const file_descriptor = try machine.unwrap(machine.file, BackendError.ArchiveOpenFailed);

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

    _ = c_libs.archive_read_open_fd(archive_reader, file_descriptor.handle, 16384);

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
            const entry_unwraped = try machine.unwrap(entry, BackendError.ArchiveReadFailed);
            const pkginfo_size: usize = @intCast(c_libs.archive_entry_size(entry_unwraped));
            const pkginfo_buf = try machine.allocator.alloc(u8, pkginfo_size);

            if (c_libs.archive_read_data(archive_reader, pkginfo_buf.ptr, pkginfo_size) < 0) {
                machine.allocator.free(pkginfo_buf);
                stateFailed(machine);
                return BackendError.ArchiveReadFailed;
            }
            machine.pkginfo_content = pkginfo_buf;
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
    try machine.check(machine.enter(.reading_meta), BackendError.OutOfMemory);

    const temp_path_c = try machine.unwrap(machine.temp_path, BackendError.TempDirFailed);
    var temp_dir = try machine.check(std.fs.openDirAbsolute(temp_path_c, .{}), BackendError.TempDirFailed);
    defer temp_dir.close();

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

        const field = package_meta_field_map.get(key) orelse continue;
        switch (field) {
            .Package => name = try machine.allocator.dupe(u8, value),
            .Version => version = try machine.allocator.dupe(u8, value),
            .@"Installed-Size" => size = std.fmt.parseInt(u32, value, 10) catch 0,
            .Architecture => arch = try machine.allocator.dupe(u8, value),
            .Description => description = try machine.allocator.dupe(u8, value),
            .License => license = try machine.allocator.dupe(u8, value),
            .Homepage => url = try machine.allocator.dupe(u8, value),
            .Maintainer => packager = try machine.allocator.dupe(u8, value),
        }
    }

    machine.meta = PackageMeta{
        .name = try machine.unwrap(name, BackendError.MetadataNotFound),
        .version = try machine.unwrap(version, BackendError.MetadataNotFound),
        .arch = arch orelse try machine.allocator.dupe(u8, "any"),
        .author = packager orelse try machine.allocator.dupe(u8, ""),
        .packager = packager orelse try machine.allocator.dupe(u8, ""),
        .description = description orelse try machine.allocator.dupe(u8, ""),
        .license = license orelse try machine.allocator.dupe(u8, ""),
        .url = url orelse try machine.allocator.dupe(u8, ""),
        .checksum = try machine.allocator.dupe(u8, machine.request.checksum),

        .size = size,
        .installed_at = std.time.timestamp(),
    };

    const alpm_junk_files = [_][]const u8{ ".BUILDINFO", ".MTREE", ".INSTALL", ".CHANGELOG" };
    for (alpm_junk_files) |filename| temp_dir.deleteFile(filename) catch {};

    return stateDone(machine);
}

// The final state representing the successful completion of all processing stages
fn stateDone(machine: *Machine) BackendError!void {
    try machine.check(machine.enter(.done), BackendError.OutOfMemory);
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
