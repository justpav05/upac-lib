// ── Imports ─────────────────────────────────────────────────────────────────────
const backend = @import("backend.zig");
const std = backend.std;
const c_libs = backend.c_libs;

const Machine = backend.BackendMachine;
const PackageMeta = backend.PackageMeta;
const BackendError = backend.BackendError;

const rpm_parser = @import("parser.zig");

// ── States ─────────────────────────────────────────────────────────────────
// Archive integrity check status: calculating SHA256 and comparing against expected value
pub fn stateVerifying(machine: *Machine) BackendError!void {
    try machine.check(machine.enter(.verifying), BackendError.OutOfMemory);

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var hasher_buf: [65536]u8 = undefined;

    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    var expected_bytes: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;

    const package_file = try machine.check(std.fs.openFileAbsoluteZ(machine.request.package_path, .{}), BackendError.ReadFailed);
    machine.file = package_file;

    while (true) {
        const index = try machine.check(package_file.read(&hasher_buf), BackendError.ReadFailed);

        if (index == 0) break;
        hasher.update(hasher_buf[0..index]);
    }
    hasher.final(&digest);

    _ = try machine.check(std.fmt.hexToBytes(&expected_bytes, machine.request.checksum.ptr[0..machine.request.checksum.len]), BackendError.InvalidPackage);

    if (!std.mem.eql(u8, &digest, &expected_bytes)) {
        stateFailed(machine);
        return BackendError.ChecksumMismatch;
    }

    const file_descriptor = try machine.unwrap(machine.file, BackendError.ArchiveOpenFailed);
    try machine.check(file_descriptor.seekTo(0), BackendError.ArchiveOpenFailed);

    return stateExtracting(machine);
}

// Parses the RPM header to extract package information into the machine metadata
fn stateReadingMeta(machine: *Machine) BackendError!void {
    try machine.check(machine.enter(.reading_meta), BackendError.OutOfMemory);

    const package_file = try machine.unwrap(machine.file, BackendError.InvalidPackage);

    var rpm_header = try machine.check(rpm_parser.parseHeader(machine.allocator, package_file), BackendError.InvalidPackage);
    defer rpm_header.deinit(machine.allocator);

    const name = try machine.unwrap(rpm_header.name, BackendError.MetadataNotFound);
    const version = try machine.unwrap(rpm_header.name, BackendError.MetadataNotFound);
    const arch = try machine.unwrap(rpm_header.name, BackendError.MetadataNotFound);

    machine.meta = PackageMeta{
        .name = try machine.check(machine.allocator.dupe(u8, name), BackendError.MetadataNotFound),
        .version = try machine.check(machine.allocator.dupe(u8, version), BackendError.MetadataNotFound),
        .arch = try machine.check(machine.allocator.dupe(u8, arch), BackendError.MetadataNotFound),
        .author = try machine.check(machine.allocator.dupe(u8, rpm_header.packager orelse ""), BackendError.MetadataNotFound),
        .description = try machine.check(machine.allocator.dupe(u8, rpm_header.summary orelse ""), BackendError.MetadataNotFound),
        .license = try machine.check(machine.allocator.dupe(u8, rpm_header.license orelse ""), BackendError.MetadataNotFound),
        .packager = try machine.check(machine.allocator.dupe(u8, rpm_header.packager orelse ""), BackendError.MetadataNotFound),
        .url = try machine.check(machine.allocator.dupe(u8, rpm_header.url orelse ""), BackendError.MetadataNotFound),
        .checksum = try machine.check(machine.allocator.dupe(u8, machine.request.checksum), BackendError.MetadataNotFound),

        .size = rpm_header.size,
        .installed_at = std.time.timestamp(),
    };

    return stateExtracting(machine);
}

// Unpacks the contents of an archive into a target directory using libarchive
fn stateExtracting(machine: *Machine) BackendError!void {
    try machine.check(machine.enter(.extracting), BackendError.OutOfMemory);

    var temp_dir_name_buf: [256]u8 = undefined;
    const timestamp = std.time.milliTimestamp();

    const tepm_dir_name = try machine.check(std.fmt.bufPrintZ(&temp_dir_name_buf, "upac-installer-{d}", .{timestamp}), BackendError.AllocZFailed);

    const temp_dir_path_c = try machine.check(std.fs.path.joinZ(machine.allocator, &.{ std.mem.span(machine.request.temp_dir), tepm_dir_name }), BackendError.OutOfMemory);

    std.fs.makeDirAbsolute(temp_dir_path_c) catch {
        machine.allocator.free(temp_dir_path_c);
        stateFailed(machine);
        return BackendError.TempDirFailed;
    };
    machine.temp_path = temp_dir_path_c;

    const archive_reader = try machine.unwrap(c_libs.archive_read_new(), BackendError.ArchiveOpenFailed);
    defer _ = c_libs.archive_read_free(archive_reader);

    _ = c_libs.archive_read_support_format_all(archive_reader);
    _ = c_libs.archive_read_support_filter_all(archive_reader);

    if (c_libs.archive_read_open_filename(archive_reader, machine.request.package_path, 16384) != c_libs.ARCHIVE_OK) {
        stateFailed(machine);
        return BackendError.ArchiveOpenFailed;
    }

    const archive_writer = try machine.unwrap(c_libs.archive_write_disk_new(), BackendError.ArchiveOpenFailed);
    defer _ = c_libs.archive_write_free(archive_writer);

    _ = c_libs.archive_write_disk_set_options(
        archive_writer,
        c_libs.ARCHIVE_EXTRACT_TIME |
            c_libs.ARCHIVE_EXTRACT_PERM |
            c_libs.ARCHIVE_EXTRACT_FFLAGS,
    );
    _ = c_libs.archive_write_disk_set_standard_lookup(archive_writer);

    var current_directory_buffer: [std.os.linux.PATH_MAX]u8 = undefined;
    const current_directory_path = try machine.check(std.posix.getcwd(&current_directory_buffer), BackendError.OutOfMemory);

    var original_directory = try machine.check(std.fs.openDirAbsolute(current_directory_path, .{}), BackendError.ReadFailed);
    defer original_directory.close();

    try machine.check(std.posix.chdir(temp_dir_path_c), BackendError.TempDirFailed);
    defer original_directory.setAsCwd() catch {};

    while (true) {
        var archive_entry: ?*c_libs.archive_entry = null;
        const read_result = c_libs.archive_read_next_header(archive_reader, &archive_entry);
        if (read_result == c_libs.ARCHIVE_EOF) break;
        if (read_result != c_libs.ARCHIVE_OK) {
            stateFailed(machine);
            return BackendError.ArchiveReadFailed;
        }

        if (c_libs.archive_write_header(archive_writer, archive_entry) != c_libs.ARCHIVE_OK) {
            stateFailed(machine);
            return BackendError.ArchiveExtractFailed;
        }

        while (true) {
            var data_block: ?*const anyopaque = null;
            var block_size: usize = 0;
            var block_offset: i64 = 0;

            const block_result = c_libs.archive_read_data_block(archive_reader, &data_block, &block_size, &block_offset);
            if (block_result == c_libs.ARCHIVE_EOF) break;
            if (block_result != c_libs.ARCHIVE_OK) {
                stateFailed(machine);
                return BackendError.ArchiveReadFailed;
            }

            if (c_libs.archive_write_data_block(archive_writer, data_block, block_size, block_offset) != c_libs.ARCHIVE_OK) {
                stateFailed(machine);
                return BackendError.ArchiveExtractFailed;
            }
        }

        if (c_libs.archive_write_finish_entry(archive_writer) != c_libs.ARCHIVE_OK) {
            stateFailed(machine);
            return BackendError.ArchiveExtractFailed;
        }
    }

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
