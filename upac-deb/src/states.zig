// ── Imports ─────────────────────────────────────────────────────────────────────
const backend = @import("backend.zig");
const std = backend.std;
const posix = backend.std.posix;
const c_libs = backend.c_libs;

const Machine = backend.BackendMachine;
const PackageMeta = backend.PackageMeta;
const package_meta_field_map = backend.package_meta_field_map;

const BackendError = backend.BackendError;

const parseLicenseFromCopyright = backend.parseLicenseFromCopyright;

const copyArchiveEntry = backend.copyArchiveEntry;

const computeMd5 = backend.computeMd5;

const isControlFile = backend.isControlFile;
const isCopyrightFile = backend.isCopyrightFile;

const readFileFromNestedTar = backend.readFileFromNestedTar;

// ── States ─────────────────────────────────────────────────────────────────
// Archive integrity check status: calculating SHA256 and comparing against expected value
pub fn stateVerifying(machine: *Machine) BackendError!void {
    try machine.check(machine.enter(.verifying), BackendError.OutOfMemory);

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var hasher_buf: [4096]u8 = undefined;

    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    var actual: [std.crypto.hash.sha2.Sha256.digest_length * 2]u8 = undefined;

    const package_file = try machine.check(std.fs.openFileAbsoluteZ(machine.request.pkg_path, .{}), BackendError.ReadFailed);
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
    const temp_dir_path = try machine.check(std.fs.path.joinZ(machine.allocator, &.{ std.mem.span(machine.request.temp_dir), tepm_dir_name }), BackendError.AllocZFailed);

    try machine.check(std.fs.makeDirAbsolute(temp_dir_path), BackendError.TempDirFailed);
    machine.temp_path = temp_dir_path;

    const archive_reader = try machine.unwrap(c_libs.archive_read_new(), BackendError.ArchiveOpenFailed);
    defer _ = c_libs.archive_read_free(archive_reader);

    _ = c_libs.archive_read_support_format_ar(archive_reader);
    _ = c_libs.archive_read_support_filter_all(archive_reader);

    if (c_libs.archive_read_open_filename(archive_reader, machine.request.pkg_path, 16384) != c_libs.ARCHIVE_OK) {
        stateFailed(machine);
        return BackendError.ArchiveOpenFailed;
    }

    const archive_writer = c_libs.archive_write_disk_new() orelse {
        stateFailed(machine);
        return BackendError.ArchiveOpenFailed;
    };
    defer _ = c_libs.archive_write_free(archive_writer);

    _ = c_libs.archive_write_disk_set_options(
        archive_writer,
        c_libs.ARCHIVE_EXTRACT_TIME |
            c_libs.ARCHIVE_EXTRACT_PERM |
            c_libs.ARCHIVE_EXTRACT_FFLAGS,
    );
    _ = c_libs.archive_write_disk_set_standard_lookup(archive_writer);

    var buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
    const cwd_path = std.posix.getcwd(&buf) catch {
        stateFailed(machine);
        return BackendError.OutOfMemory;
    };

    var old_dir = try machine.check(std.fs.openDirAbsolute(cwd_path, .{}), BackendError.ReadFailed);
    defer old_dir.close();

    try machine.check(posix.chdir(temp_dir_path), BackendError.OutOfMemory);
    defer old_dir.setAsCwd() catch {};

    var entry: ?*c_libs.archive_entry = null;
    while (c_libs.archive_read_next_header(archive_reader, &entry) == c_libs.ARCHIVE_OK) {
        const entry_name = std.mem.span(c_libs.archive_entry_pathname(entry));

        if (std.mem.startsWith(u8, entry_name, "data.tar")) {
            const size = @as(usize, @intCast(c_libs.archive_entry_size(entry)));
            const data_tar_buffer = try machine.check(machine.allocator.alloc(u8, size), BackendError.OutOfMemory);
            defer machine.allocator.free(data_tar_buffer);

            if (c_libs.archive_read_data(archive_reader, data_tar_buffer.ptr, size) < 0) {
                stateFailed(machine);
                return BackendError.ArchiveReadFailed;
            }

            const inner_archive_reader = try machine.unwrap(c_libs.archive_read_new(), BackendError.ArchiveOpenFailed);
            defer _ = c_libs.archive_read_free(inner_archive_reader);

            _ = c_libs.archive_read_support_format_tar(inner_archive_reader);
            _ = c_libs.archive_read_support_filter_all(inner_archive_reader);

            if (c_libs.archive_read_open_memory(inner_archive_reader, data_tar_buffer.ptr, size) != c_libs.ARCHIVE_OK) {
                stateFailed(machine);
                return BackendError.ArchiveOpenFailed;
            }

            var inner_entry: ?*c_libs.archive_entry = null;
            while (c_libs.archive_read_next_header(inner_archive_reader, &inner_entry) == c_libs.ARCHIVE_OK) {
                if (c_libs.archive_write_header(archive_writer, inner_entry) != c_libs.ARCHIVE_OK) {
                    stateFailed(machine);
                    return BackendError.ArchiveExtractFailed;
                }
                try copyArchiveEntry(inner_archive_reader, archive_writer, machine);
            }
        }
    }
    return stateVerifyingFiles(machine);
}

// Verifies the checksums of files listed in md5sums against their actual contents on disk
fn stateVerifyingFiles(machine: *Machine) BackendError!void {
    try machine.check(machine.enter(.special_step), BackendError.OutOfMemory);
    machine.reportDetail("verifying archive integrity...");

    const md5_path = try machine.check(std.fs.path.join(machine.allocator, &.{ std.mem.span(machine.request.temp_dir), "md5sums" }), BackendError.OutOfMemory);
    defer machine.allocator.free(md5_path);

    const content = std.fs.cwd().readFileAlloc(machine.allocator, md5_path, 10 * 1024 * 1024) catch |err| {
        if (err == error.FileNotFound) return stateReadingMeta(machine);
        stateFailed(machine);
        return BackendError.ReadFailed;
    };
    defer machine.allocator.free(content);

    var temp_dir = try machine.check(std.fs.openDirAbsolute(std.mem.span(machine.request.temp_dir), .{}), BackendError.ReadFailed);
    defer temp_dir.close();

    var io_buf: [4096]u8 = undefined;
    var lines = std.mem.splitScalar(u8, content, '\n');

    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \r");
        if (trimmed.len == 0) continue;

        var tokens = std.mem.tokenizeAny(u8, trimmed, " \t");
        const expected_hex = tokens.next() orelse continue;
        const file_path = std.mem.trim(u8, tokens.rest(), " \t");

        const file = try machine.check(temp_dir.openFile(file_path, .{}), BackendError.ReadFailed);
        defer file.close();

        const digest = try machine.check(computeMd5(file, &io_buf), BackendError.ReadFailed);
        const actual_hex = std.fmt.bytesToHex(digest, .lower);

        if (!std.mem.eql(u8, &actual_hex, expected_hex)) {
            stateFailed(machine);
            return BackendError.ChecksumMismatch;
        }
    }

    return stateReadingMeta(machine);
}

// Extracts package metadata from the nested control.tar archive and parses the control file
fn stateReadingMeta(machine: *Machine) BackendError!void {
    try machine.check(machine.enter(.reading_meta), BackendError.OutOfMemory);

    const archive_reader = try machine.unwrap(c_libs.archive_read_new(), BackendError.ArchiveOpenFailed);
    defer _ = c_libs.archive_read_free(archive_reader);
    _ = c_libs.archive_read_support_format_ar(archive_reader);
    _ = c_libs.archive_read_support_filter_all(archive_reader);

    if (c_libs.archive_read_open_filename(archive_reader, machine.request.pkg_path, 16384) != c_libs.ARCHIVE_OK) {
        stateFailed(machine);
        return BackendError.ArchiveOpenFailed;
    }

    var control_content: ?[]u8 = null;
    defer if (control_content) |c| machine.allocator.free(c);

    var copyright_content: ?[]u8 = null;
    defer if (copyright_content) |c| machine.allocator.free(c);

    var entry: ?*c_libs.archive_entry = null;
    outer: while (c_libs.archive_read_next_header(archive_reader, &entry) == c_libs.ARCHIVE_OK) {
        const entry_name = std.mem.span(c_libs.archive_entry_pathname(entry));

        if (std.mem.startsWith(u8, entry_name, "control.tar")) {
            control_content = try readFileFromNestedTar(machine, archive_reader, entry, isControlFile);
        } else if (std.mem.startsWith(u8, entry_name, "data.tar")) {
            copyright_content = try readFileFromNestedTar(machine, archive_reader, entry, isCopyrightFile);
        }

        if (control_content != null and copyright_content != null) break :outer;
    }

    if (control_content == null) {
        stateFailed(machine);
        return BackendError.InvalidPackage;
    }

    var name: ?[]const u8 = null;
    var version: ?[]const u8 = null;
    var size: u32 = 0;
    var architecture: ?[]const u8 = null;
    var description: ?[]const u8 = null;
    var url: ?[]const u8 = null;
    var packager: ?[]const u8 = null;

    var lines = std.mem.splitScalar(u8, control_content.?, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;

        const separator_index = std.mem.indexOf(u8, trimmed, ": ") orelse continue;
        const key = trimmed[0..separator_index];
        const value = std.mem.trim(u8, trimmed[separator_index + 2 ..], " \t");

        const field = package_meta_field_map.get(key) orelse continue;
        switch (field) {
            .Package => name = try machine.allocator.dupe(u8, value),
            .Version => version = try machine.allocator.dupe(u8, value),
            .@"Installed-Size" => size = std.fmt.parseInt(u32, value, 10) catch 0,
            .Architecture => architecture = try machine.allocator.dupe(u8, value),
            .Description => description = try machine.allocator.dupe(u8, value),
            .Homepage => url = try machine.allocator.dupe(u8, value),
            .Maintainer => packager = try machine.allocator.dupe(u8, value),
        }
    }

    machine.meta = PackageMeta{
        .name = try machine.unwrap(name, BackendError.MetadataNotFound),
        .version = try machine.unwrap(version, BackendError.MetadataNotFound),
        .author = packager orelse try machine.allocator.dupe(u8, "Unknown"),
        .size = size,
        .architecture = architecture orelse try machine.allocator.dupe(u8, "No architecture"),
        .description = description orelse try machine.allocator.dupe(u8, "No description"),
        .license = try parseLicenseFromCopyright(copyright_content, machine.allocator),
        .url = url orelse try machine.allocator.dupe(u8, "No url"),
        .packager = packager orelse try machine.allocator.dupe(u8, "Unknown"),
        .installed_at = std.time.timestamp(),
        .checksum = try machine.allocator.dupe(u8, machine.request.checksum),
    };

    return stateDone(machine);
}

// The final state representing the successful completion of all processing stages
fn stateDone(machine: *Machine) BackendError!void {
    try machine.check(machine.enter(.done), BackendError.OutOfMemory);
}

// An error state signaling that the machine failed to reach the required state at a certain stage
pub fn stateFailed(machine: *Machine) void {
    machine.enter(.failed) catch {};
    if (machine.temp_path) |path| {
        std.fs.deleteTreeAbsolute(path) catch {};
        machine.allocator.free(path);
        machine.temp_path = null;
    }
    _ = machine.enter(.failed) catch {};
}
