// ── Imports ─────────────────────────────────────────────────────────────────────
const std = @import("std");

const backend = @import("backend.zig");
const Machine = backend.BackendMachine;
const PackageMeta = backend.PackageMeta;
const BackendError = backend.BackendError;

const rpm_parser = @import("parser.zig");

const c_libs = @cImport({
    @cInclude("archive.h");
    @cInclude("archive_entry.h");
});

// ── States ─────────────────────────────────────────────────────────────────
// Archive integrity check status: calculating SHA256 and comparing against expected value
pub fn stateVerifying(machine: *Machine) BackendError!void {
    machine.enter(.verifying) catch {
        stateFailed(machine);
        return BackendError.OutOfMemory;
    };

    const package_path_c = std.fmt.allocPrintZ(machine.allocator, "{s}", .{machine.request.package_path}) catch {
        stateFailed(machine);
        return BackendError.OutOfMemory;
    };
    defer machine.allocator.free(package_path_c);

    const package_file = std.fs.openFileAbsolute(package_path_c, .{}) catch {
        stateFailed(machine);
        return BackendError.ReadFailed;
    };
    defer package_file.close();

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var read_buffer: [4096]u8 = undefined;

    while (true) {
        const bytes_read = package_file.read(&read_buffer) catch {
            stateFailed(machine);
            return BackendError.ReadFailed;
        };
        if (bytes_read == 0) break;
        hasher.update(read_buffer[0..bytes_read]);
    }

    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    hasher.final(&digest);

    var actual_checksum: [std.crypto.hash.sha2.Sha256.digest_length * 2]u8 = undefined;
    _ = std.fmt.bufPrint(&actual_checksum, "{}", .{std.fmt.fmtSliceHexLower(&digest)}) catch {
        stateFailed(machine);
        return BackendError.ReadFailed;
    };

    if (!std.mem.eql(u8, &actual_checksum, machine.request.checksum)) {
        stateFailed(machine);
        return BackendError.ChecksumMismatch;
    }

    return stateReadingMeta(machine);
}

// Parses the RPM header to extract package information into the machine metadata
fn stateReadingMeta(machine: *Machine) BackendError!void {
    machine.enter(.reading_meta) catch {
        stateFailed(machine);
        return BackendError.OutOfMemory;
    };

    const package_file = std.fs.openFileAbsolute(machine.request.package_path, .{}) catch {
        stateFailed(machine);
        return BackendError.ReadFailed;
    };
    defer package_file.close();

    var rpm_header = rpm_parser.parseHeader(machine.allocator, package_file) catch {
        stateFailed(machine);
        return BackendError.InvalidPackage;
    };
    defer rpm_header.deinit(machine.allocator);

    machine.meta = PackageMeta{
        .name = machine.allocator.dupe(u8, rpm_header.name.?) catch {
            stateFailed(machine);
            return BackendError.MetadataNotFound;
        },
        .version = machine.allocator.dupe(u8, rpm_header.version.?) catch {
            stateFailed(machine);
            return BackendError.MetadataNotFound;
        },
        .size = rpm_header.size,
        .arch = machine.allocator.dupe(u8, rpm_header.arch.?) catch {
            stateFailed(machine);
            return BackendError.MetadataNotFound;
        },
        .author = machine.allocator.dupe(u8, rpm_header.packager orelse "") catch {
            stateFailed(machine);
            return BackendError.MetadataNotFound;
        },
        .description = machine.allocator.dupe(u8, rpm_header.summary orelse "") catch {
            stateFailed(machine);
            return BackendError.MetadataNotFound;
        },
        .license = machine.allocator.dupe(u8, rpm_header.license orelse "") catch {
            stateFailed(machine);
            return BackendError.MetadataNotFound;
        },
        .packager = machine.allocator.dupe(u8, rpm_header.packager orelse "") catch {
            stateFailed(machine);
            return BackendError.MetadataNotFound;
        },
        .url = machine.allocator.dupe(u8, rpm_header.url orelse "") catch {
            stateFailed(machine);
            return BackendError.MetadataNotFound;
        },
        .installed_at = std.time.timestamp(),
        .checksum = machine.allocator.dupe(u8, machine.request.checksum) catch {
            stateFailed(machine);
            return BackendError.MetadataNotFound;
        },
    };

    return stateExtracting(machine);
}

// Unpacks the contents of an archive into a target directory using libarchive
fn stateExtracting(machine: *Machine) BackendError!void {
    machine.enter(.extracting) catch {
        stateFailed(machine);
        return BackendError.OutOfMemory;
    };

    const package_path_c = std.fmt.allocPrintZ(machine.allocator, "{s}", .{machine.request.package_path}) catch {
        stateFailed(machine);
        return BackendError.OutOfMemory;
    };
    defer machine.allocator.free(package_path_c);

    const temp_path_c = std.fmt.allocPrintZ(machine.allocator, "{s}/upac_{d}", .{ machine.request.temp_dir, std.time.milliTimestamp() }) catch {
        stateFailed(machine);
        return BackendError.OutOfMemory;
    };
    std.fs.makeDirAbsolute(temp_path_c) catch {
        machine.allocator.free(temp_path_c);
        stateFailed(machine);
        return BackendError.TempDirFailed;
    };
    machine.temp_path = temp_path_c;

    const archive_reader = c_libs.archive_read_new() orelse {
        stateFailed(machine);
        return BackendError.ArchiveOpenFailed;
    };
    defer _ = c_libs.archive_read_free(archive_reader);

    _ = c_libs.archive_read_support_format_all(archive_reader);
    _ = c_libs.archive_read_support_filter_all(archive_reader);

    if (c_libs.archive_read_open_filename(archive_reader, package_path_c.ptr, 16384) != c_libs.ARCHIVE_OK) {
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

    var current_directory_buffer: [std.fs.MAX_PATH_BYTES]u8 = undefined;
    const current_directory_path = std.posix.getcwd(&current_directory_buffer) catch {
        stateFailed(machine);
        return BackendError.OutOfMemory;
    };

    var original_directory = std.fs.openDirAbsolute(current_directory_path, .{}) catch {
        stateFailed(machine);
        return BackendError.ReadFailed;
    };
    defer original_directory.close();

    std.posix.chdir(temp_path_c) catch {
        stateFailed(machine);
        return BackendError.TempDirFailed;
    };
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
