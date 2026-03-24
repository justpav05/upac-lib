const std = @import("std");
const posix = std.posix;

const backend = @import("backend.zig");
const Machine = backend.Machine;
const PackageMeta = backend.PackageMeta;
const BackendError = backend.BackendError;

const c_libs = @cImport({
    @cInclude("archive.h");
    @cInclude("archive_entry.h");
});

// ── Состояния ─────────────────────────────────────────────────────────────────
pub fn stateVerifying(backend_machine: *Machine) anyerror!void {
    try backend_machine.enter(.verifying);

    const path_z = try std.fmt.allocPrintZ(backend_machine.allocator, "{s}", .{backend_machine.request.pkg_path});
    defer backend_machine.allocator.free(path_z);

    const file = std.fs.openFileAbsolute(path_z, .{}) catch |err| {
        stateFailed(backend_machine);
        return err;
    };
    defer file.close();

    var sha256_hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var sha256_buf: [4096]u8 = undefined;

    while (true) {
        const number = file.read(&sha256_buf) catch {
            stateFailed(backend_machine);
            return BackendError.ReadFailed;
        };
        if (number == 0) break;
        sha256_hasher.update(sha256_buf[0..number]);
    }

    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    sha256_hasher.final(&digest);

    var actual: [std.crypto.hash.sha2.Sha256.digest_length * 2]u8 = undefined;
    _ = std.fmt.bufPrint(&actual, "{}", .{std.fmt.fmtSliceHexLower(&digest)}) catch {
        stateFailed(backend_machine);
        return BackendError.ReadFailed;
    };

    if (!std.mem.eql(u8, &actual, backend_machine.request.checksum)) {
        stateFailed(backend_machine);
        return BackendError.ChecksumMismatch;
    }

    return stateExtracting(backend_machine);
}

fn stateExtracting(backend_machine: *Machine) anyerror!void {
    try backend_machine.enter(.extracting);

    const package_path_c = try std.fmt.allocPrintZ(backend_machine.allocator, "{s}", .{backend_machine.request.pkg_path});
    defer backend_machine.allocator.free(package_path_c);

    const temp_path_c = try std.fmt.allocPrintZ(backend_machine.allocator, "{s}", .{backend_machine.request.out_path});
    defer backend_machine.allocator.free(temp_path_c);

    const archive_reader = c_libs.archive_read_new() orelse {
        stateFailed(backend_machine);
        return BackendError.ArchiveOpenFailed;
    };
    defer _ = c_libs.archive_read_free(archive_reader);

    _ = c_libs.archive_read_support_format_ar(archive_reader);
    _ = c_libs.archive_read_support_filter_all(archive_reader);

    if (c_libs.archive_read_open_filename(archive_reader, package_path_c.ptr, 16384) != c_libs.ARCHIVE_OK) {
        stateFailed(backend_machine);
        return BackendError.ArchiveOpenFailed;
    }

    const archive_writer = c_libs.archive_write_disk_new() orelse {
        stateFailed(backend_machine);
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
    const cwd_path = try std.posix.getcwd(&buf);

    var old_dir = try std.fs.openDirAbsolute(cwd_path, .{});
    defer old_dir.close();

    try posix.chdir(temp_path_c);
    defer old_dir.setAsCwd() catch {};

    var entry: ?*c_libs.archive_entry = null;
    while (c_libs.archive_read_next_header(archive_reader, &entry) == c_libs.ARCHIVE_OK) {
        const entry_name = std.mem.span(c_libs.archive_entry_pathname(entry));

        if (std.mem.startsWith(u8, entry_name, "data.tar")) {
            const size = @as(usize, @intCast(c_libs.archive_entry_size(entry)));
            const buffer = try backend_machine.allocator.alloc(u8, size);
            defer backend_machine.allocator.free(buffer);

            if (c_libs.archive_read_data(archive_reader, buffer.ptr, size) < 0) {
                stateFailed(backend_machine);
                return BackendError.ArchiveReadFailed;
            }

            const inner_archive_reader = c_libs.archive_read_new() orelse return BackendError.ArchiveOpenFailed;
            defer _ = c_libs.archive_read_free(inner_archive_reader);

            _ = c_libs.archive_read_support_format_tar(inner_archive_reader);
            _ = c_libs.archive_read_support_filter_all(inner_archive_reader);

            if (c_libs.archive_read_open_memory(inner_archive_reader, buffer.ptr, size) != c_libs.ARCHIVE_OK) {
                stateFailed(backend_machine);
                return BackendError.ArchiveOpenFailed;
            }

            var inner_entry: ?*c_libs.archive_entry = null;
            while (c_libs.archive_read_next_header(inner_archive_reader, &inner_entry) == c_libs.ARCHIVE_OK) {
                if (c_libs.archive_write_header(archive_writer, inner_entry) != c_libs.ARCHIVE_OK) {
                    stateFailed(backend_machine);
                    return BackendError.ArchiveExtractFailed;
                }

                while (true) {
                    var block: ?*const anyopaque = null;
                    var b_size: usize = 0;
                    var offset: i64 = 0;

                    const rd = c_libs.archive_read_data_block(inner_archive_reader, &block, &b_size, &offset);
                    if (rd == c_libs.ARCHIVE_EOF) break;
                    if (rd != c_libs.ARCHIVE_OK) {
                        stateFailed(backend_machine);
                        return BackendError.ArchiveReadFailed;
                    }

                    if (c_libs.archive_write_data_block(archive_writer, block, b_size, offset) != c_libs.ARCHIVE_OK) {
                        stateFailed(backend_machine);
                        return BackendError.ArchiveExtractFailed;
                    }
                }
            }
            break;
        }
    }
    return stateVerifyingFiles(backend_machine);
}

fn stateVerifyingFiles(backend_machine: *Machine) anyerror!void {
    try backend_machine.enter(.verifying_files);

    const md5_path = try std.fs.path.join(backend_machine.allocator, &.{ backend_machine.request.out_path, "md5sums" });
    defer backend_machine.allocator.free(md5_path);

    const content = std.fs.cwd().readFileAlloc(backend_machine.allocator, md5_path, 10 * 1024 * 1024) catch |err| {
        if (err == error.FileNotFound) return stateReadingMeta(backend_machine);
        stateFailed(backend_machine);
        return err;
    };
    defer backend_machine.allocator.free(content);

    var split_lines_iterator = std.mem.splitScalar(u8, content, '\n');
    while (split_lines_iterator.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \r");
        if (trimmed.len == 0) continue;

        var token_iter = std.mem.tokenizeAny(u8, trimmed, " \t");
        const expected_hash_hex = token_iter.next() orelse continue;
        const file_path = token_iter.rest();

        const full_file_path = try std.fs.path.join(backend_machine.allocator, &.{ backend_machine.request.out_path, file_path });
        defer backend_machine.allocator.free(full_file_path);

        const file = std.fs.openFileAbsolute(full_file_path, .{}) catch {
            stateFailed(backend_machine);
            return BackendError.ReadFailed;
        };
        defer file.close();

        var md5_hasher = std.crypto.hash.Md5.init(.{});
        var md5_buf: [4096]u8 = undefined;
        while (true) {
            const number = try file.read(&md5_buf);
            if (number == 0) break;
            md5_hasher.update(md5_buf[0..number]);
        }

        var digest: [std.crypto.hash.Md5.digest_length]u8 = undefined;
        md5_hasher.final(&digest);
        var actual_hex: [std.crypto.hash.Md5.digest_length * 2]u8 = undefined;
        _ = try std.fmt.bufPrint(&actual_hex, "{}", .{std.fmt.fmtSliceHexLower(&digest)});

        if (!std.mem.eql(u8, &actual_hex, expected_hash_hex)) {
            std.debug.print("MD5 mismatch for {s}\n", .{file_path});
            stateFailed(backend_machine);
            return BackendError.ChecksumMismatch;
        }
    }

    return stateReadingMeta(backend_machine);
}

fn stateReadingMeta(backend_machine: *Machine) anyerror!void {
    try backend_machine.enter(.reading_meta);

    const pkg_path_c = try std.fmt.allocPrintZ(backend_machine.allocator, "{s}", .{backend_machine.request.pkg_path});
    defer backend_machine.allocator.free(pkg_path_c);

    const archive_reader = c_libs.archive_read_new() orelse return BackendError.ArchiveOpenFailed;
    defer _ = c_libs.archive_read_free(archive_reader);
    _ = c_libs.archive_read_support_format_ar(archive_reader);
    _ = c_libs.archive_read_support_filter_all(archive_reader);

    if (c_libs.archive_read_open_filename(archive_reader, pkg_path_c.ptr, 16384) != c_libs.ARCHIVE_OK) {
        stateFailed(backend_machine);
        return BackendError.ArchiveOpenFailed;
    }

    var control_content: ?[]u8 = null;
    defer if (control_content) |c| backend_machine.allocator.free(c);

    var entry: ?*c_libs.archive_entry = null;
    while (c_libs.archive_read_next_header(archive_reader, &entry) == c_libs.ARCHIVE_OK) {
        const entry_name = std.mem.span(c_libs.archive_entry_pathname(entry));

        if (std.mem.startsWith(u8, entry_name, "control.tar")) {
            const size = @as(usize, @intCast(c_libs.archive_entry_size(entry)));
            const tar_buffer = try backend_machine.allocator.alloc(u8, size);
            defer backend_machine.allocator.free(tar_buffer);

            if (c_libs.archive_read_data(archive_reader, tar_buffer.ptr, size) < 0) return BackendError.ArchiveReadFailed;

            const inner_archive_reader = c_libs.archive_read_new() orelse return BackendError.ArchiveOpenFailed;
            defer _ = c_libs.archive_read_free(inner_archive_reader);
            _ = c_libs.archive_read_support_format_tar(inner_archive_reader);
            _ = c_libs.archive_read_support_filter_all(inner_archive_reader);

            if (c_libs.archive_read_open_memory(inner_archive_reader, tar_buffer.ptr, size) == c_libs.ARCHIVE_OK) {
                var inner_entry: ?*c_libs.archive_entry = null;
                while (c_libs.archive_read_next_header(inner_archive_reader, &inner_entry) == c_libs.ARCHIVE_OK) {
                    const inner_name = std.mem.span(c_libs.archive_entry_pathname(inner_entry));
                    if (std.mem.endsWith(u8, inner_name, "control")) {
                        const c_size = @as(usize, @intCast(c_libs.archive_entry_size(inner_entry)));
                        control_content = try backend_machine.allocator.alloc(u8, c_size);
                        _ = c_libs.archive_read_data(inner_archive_reader, control_content.?.ptr, c_size);
                        break;
                    }
                }
            }
            break;
        }
    }

    if (control_content == null) {
        stateFailed(backend_machine);
        return BackendError.InvalidPackage;
    }

    var name: ?[]const u8 = null;
    var version: ?[]const u8 = null;
    var description: ?[]const u8 = null;
    var url: ?[]const u8 = null;
    var packager: ?[]const u8 = null;

    var lines = std.mem.splitScalar(u8, control_content.?, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;

        const sep = std.mem.indexOf(u8, trimmed, ": ") orelse continue;
        const key = trimmed[0..sep];
        const value = std.mem.trim(u8, trimmed[sep + 2 ..], " \t");

        if (std.mem.eql(u8, key, "Package")) {
            name = try backend_machine.allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "Version")) {
            version = try backend_machine.allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "Description")) {
            description = try backend_machine.allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "Homepage")) {
            url = try backend_machine.allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "Maintainer")) {
            packager = try backend_machine.allocator.dupe(u8, value);
        }
    }

    if (name == null or version == null) {
        stateFailed(backend_machine);
        return BackendError.InvalidPackage;
    }

    backend_machine.meta = PackageMeta{
        .name = name.?,
        .version = version.?,
        .author = packager orelse try backend_machine.allocator.dupe(u8, "Unknown"),
        .description = description orelse try backend_machine.allocator.dupe(u8, ""),
        .license = try backend_machine.allocator.dupe(u8, "Unknown"),
        .url = url orelse try backend_machine.allocator.dupe(u8, ""),
        .installed_at = std.time.timestamp(),
        .checksum = try backend_machine.allocator.dupe(u8, backend_machine.request.checksum),
    };

    return stateDone(backend_machine);
}

fn stateDone(backend_machine: *Machine) anyerror!void {
    try backend_machine.enter(.done);
}

fn stateFailed(backend_machine: *Machine) void {
    _ = backend_machine.enter(.failed) catch {};
    std.debug.print("✗ backend failed, path: ", .{});
    for (backend_machine.stack.items) |state_id| std.debug.print("{s} ", .{@tagName(state_id)});
    std.debug.print("\n", .{});
}
