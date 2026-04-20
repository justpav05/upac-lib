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
    machine.enter(.verifying) catch {
        stateFailed(machine);
        return BackendError.OutOfMemory;
    };

    const package_path_c = try std.fmt.allocPrintZ(machine.allocator, "{s}", .{machine.request.pkg_path});
    defer machine.allocator.free(package_path_c);

    const file = std.fs.openFileAbsolute(package_path_c, .{}) catch {
        stateFailed(machine);
        return BackendError.ReadFailed;
    };
    defer file.close();

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var buf: [4096]u8 = undefined;

    while (true) {
        const n = file.read(&buf) catch {
            stateFailed(machine);
            return BackendError.ReadFailed;
        };
        if (n == 0) break;
        hasher.update(buf[0..n]);
    }

    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    hasher.final(&digest);

    var actual: [std.crypto.hash.sha2.Sha256.digest_length * 2]u8 = undefined;
    _ = std.fmt.bufPrint(&actual, "{}", .{std.fmt.fmtSliceHexLower(&digest)}) catch {
        stateFailed(machine);
        return BackendError.ReadFailed;
    };

    if (!std.mem.eql(u8, &actual, machine.request.checksum)) {
        stateFailed(machine);
        return BackendError.ChecksumMismatch;
    }

    return stateExtracting(machine);
}

// Unpacking state: uses libarchive to extract files to the temp directory
fn stateExtracting(machine: *Machine) BackendError!void {
    machine.enter(.extracting) catch {
        stateFailed(machine);
        return BackendError.OutOfMemory;
    };

    const pkg_path_c = try std.fmt.allocPrintZ(machine.allocator, "{s}", .{machine.request.pkg_path});
    defer machine.allocator.free(pkg_path_c);

    const temp_path = try std.fmt.allocPrintZ(machine.allocator, "{s}/upac_{d}", .{ machine.request.temp_dir, std.time.milliTimestamp() });
    std.fs.makeDirAbsolute(temp_path) catch {
        machine.allocator.free(temp_path);
        stateFailed(machine);
        return BackendError.TempDirFailed;
    };
    machine.temp_path = temp_path;

    const ar = c_libs.archive_read_new() orelse {
        stateFailed(machine);
        return BackendError.ArchiveOpenFailed;
    };
    defer _ = c_libs.archive_read_free(ar);

    _ = c_libs.archive_read_support_format_tar(ar);
    _ = c_libs.archive_read_support_filter_zstd(ar);
    _ = c_libs.archive_read_support_filter_xz(ar);
    _ = c_libs.archive_read_support_filter_gzip(ar);

    if (c_libs.archive_read_open_filename(ar, pkg_path_c.ptr, 16384) != c_libs.ARCHIVE_OK) {
        stateFailed(machine);
        return BackendError.ArchiveOpenFailed;
    }

    const aw = c_libs.archive_write_disk_new() orelse {
        stateFailed(machine);
        return BackendError.ArchiveOpenFailed;
    };
    defer _ = c_libs.archive_write_free(aw);

    _ = c_libs.archive_write_disk_set_options(
        aw,
        c_libs.ARCHIVE_EXTRACT_TIME |
            c_libs.ARCHIVE_EXTRACT_PERM |
            c_libs.ARCHIVE_EXTRACT_FFLAGS,
    );
    _ = c_libs.archive_write_disk_set_standard_lookup(aw);

    var buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
    const cwd_path = std.posix.getcwd(&buf) catch {
        stateFailed(machine);
        return BackendError.TempDirFailed;
    };

    var old_dir = std.fs.openDirAbsolute(cwd_path, .{}) catch {
        stateFailed(machine);
        return BackendError.TempDirFailed;
    };
    defer old_dir.close();

    posix.chdir(temp_path) catch {
        stateFailed(machine);
        return BackendError.TempDirFailed;
    };
    defer old_dir.setAsCwd() catch {};

    while (true) {
        var entry: ?*c_libs.archive_entry = null;
        const r = c_libs.archive_read_next_header(ar, &entry);
        if (r == c_libs.ARCHIVE_EOF) break;
        if (r != c_libs.ARCHIVE_OK) {
            stateFailed(machine);
            return BackendError.ArchiveReadFailed;
        }

        if (c_libs.archive_write_header(aw, entry) != c_libs.ARCHIVE_OK) {
            stateFailed(machine);
            return BackendError.ArchiveExtractFailed;
        }

        while (true) {
            var block: ?*const anyopaque = null;
            var size: usize = 0;
            var offset: i64 = 0;

            const rd = c_libs.archive_read_data_block(ar, &block, &size, &offset);
            if (rd == c_libs.ARCHIVE_EOF) break;
            if (rd != c_libs.ARCHIVE_OK) {
                stateFailed(machine);
                return BackendError.ArchiveReadFailed;
            }

            if (c_libs.archive_write_data_block(aw, block, size, offset) != c_libs.ARCHIVE_OK) {
                stateFailed(machine);
                return BackendError.ArchiveExtractFailed;
            }
        }

        if (c_libs.archive_write_finish_entry(aw) != c_libs.ARCHIVE_OK) {
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

    const pkginfo_path = try std.fs.path.join(
        machine.allocator,
        &.{ machine.temp_path.?, ".PKGINFO" },
    );
    defer machine.allocator.free(pkginfo_path);

    const content = std.fs.cwd().readFileAlloc(machine.allocator, pkginfo_path, 64 * 1024) catch {
        stateFailed(machine);
        return BackendError.ReadFailed;
    };
    defer machine.allocator.free(content);

    // Парсим .PKGINFO
    var name: ?[]const u8 = null;
    var version: ?[]const u8 = null;
    var description: ?[]const u8 = null;
    var url: ?[]const u8 = null;
    var packager: ?[]const u8 = null;
    var license: ?[]const u8 = null;

    errdefer {
        if (name) |v| machine.allocator.free(v);
        if (version) |v| machine.allocator.free(v);
        if (description) |v| machine.allocator.free(v);
        if (url) |v| machine.allocator.free(v);
        if (packager) |v| machine.allocator.free(v);
        if (license) |v| machine.allocator.free(v);
    }

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;

        const sep = std.mem.indexOf(u8, trimmed, " = ") orelse continue;
        const key = std.mem.trim(u8, trimmed[0..sep], " \t");
        const value = std.mem.trim(u8, trimmed[sep + 3 ..], " \t");

        if (std.mem.eql(u8, key, "pkgname")) {
            name = try machine.allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "pkgver")) {
            version = try machine.allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "pkgdesc")) {
            description = try machine.allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "url")) {
            url = try machine.allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "packager")) {
            packager = try machine.allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "license")) {
            license = try machine.allocator.dupe(u8, value);
        }
    }

    if (name == null or version == null) {
        stateFailed(machine);
        return BackendError.InvalidPackage;
    }

    machine.meta = PackageMeta{
        .name = name.?,
        .version = version.?,
        .author = packager orelse try machine.allocator.dupe(u8, ""),
        .description = description orelse try machine.allocator.dupe(u8, ""),
        .license = license orelse try machine.allocator.dupe(u8, ""),
        .url = url orelse try machine.allocator.dupe(u8, ""),
        .installed_at = std.time.timestamp(),
        .checksum = try machine.allocator.dupe(u8, machine.request.checksum),
    };

    const alpm_junk_files = [_][]const u8{ ".BUILDINFO", ".MTREE", ".PKGINFO", ".INSTALL", ".CHANGELOG" };
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
