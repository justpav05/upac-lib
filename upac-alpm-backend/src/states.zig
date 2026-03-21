const std = @import("std");
const posix = std.posix;

const types = @import("types.zig");
const PackageMeta = types.PackageMeta;
const BackendError = types.BackendError;

const fsm = @import("machine.zig");
const Machine = fsm.Machine;

const c_librarys = @cImport({
    @cInclude("archive.h");
    @cInclude("archive_entry.h");
});

// ── Состояния ─────────────────────────────────────────────────────────────────
pub fn stateVerifying(machine: *Machine) anyerror!void {
    try machine.enter(.verifying);

    const path_z = try std.fmt.allocPrintZ(machine.allocator, "{s}", .{machine.request.pkg_path});
    defer machine.allocator.free(path_z);

    const file = std.fs.openFileAbsolute(path_z, .{}) catch |err| {
        stateFailed(machine);
        return err;
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

fn stateExtracting(machine: *Machine) anyerror!void {
    try machine.enter(.extracting);

    const pkg_path_c = try std.fmt.allocPrintZ(machine.allocator, "{s}", .{machine.request.pkg_path});
    defer machine.allocator.free(pkg_path_c);

    const out_path_c = try std.fmt.allocPrintZ(machine.allocator, "{s}", .{machine.request.out_path});
    defer machine.allocator.free(out_path_c);

    const ar = c_librarys.archive_read_new() orelse {
        stateFailed(machine);
        return BackendError.ArchiveOpenFailed;
    };
    defer _ = c_librarys.archive_read_free(ar);

    _ = c_librarys.archive_read_support_format_tar(ar);
    _ = c_librarys.archive_read_support_filter_zstd(ar);
    _ = c_librarys.archive_read_support_filter_xz(ar);
    _ = c_librarys.archive_read_support_filter_gzip(ar);

    if (c_librarys.archive_read_open_filename(ar, pkg_path_c.ptr, 16384) != c_librarys.ARCHIVE_OK) {
        stateFailed(machine);
        return BackendError.ArchiveOpenFailed;
    }

    const aw = c_librarys.archive_write_disk_new() orelse {
        stateFailed(machine);
        return BackendError.ArchiveOpenFailed;
    };
    defer _ = c_librarys.archive_write_free(aw);

    _ = c_librarys.archive_write_disk_set_options(
        aw,
        c_librarys.ARCHIVE_EXTRACT_TIME |
            c_librarys.ARCHIVE_EXTRACT_PERM |
            c_librarys.ARCHIVE_EXTRACT_FFLAGS,
    );
    _ = c_librarys.archive_write_disk_set_standard_lookup(aw);

    var buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
    const cwd_path = try std.posix.getcwd(&buf);

    var old_dir = try std.fs.openDirAbsolute(cwd_path, .{});
    defer old_dir.close();

    try posix.chdir(out_path_c);
    defer old_dir.setAsCwd() catch {};

    while (true) {
        var entry: ?*c_librarys.archive_entry = null;
        const r = c_librarys.archive_read_next_header(ar, &entry);
        if (r == c_librarys.ARCHIVE_EOF) break;
        if (r != c_librarys.ARCHIVE_OK) {
            stateFailed(machine);
            return BackendError.ArchiveReadFailed;
        }

        if (c_librarys.archive_write_header(aw, entry) != c_librarys.ARCHIVE_OK) {
            stateFailed(machine);
            return BackendError.ArchiveExtractFailed;
        }

        while (true) {
            var block: ?*const anyopaque = null;
            var size: usize = 0;
            var offset: i64 = 0;

            const rd = c_librarys.archive_read_data_block(ar, &block, &size, &offset);
            if (rd == c_librarys.ARCHIVE_EOF) break;
            if (rd != c_librarys.ARCHIVE_OK) {
                stateFailed(machine);
                return BackendError.ArchiveReadFailed;
            }

            if (c_librarys.archive_write_data_block(aw, block, size, offset) != c_librarys.ARCHIVE_OK) {
                stateFailed(machine);
                return BackendError.ArchiveExtractFailed;
            }
        }

        if (c_librarys.archive_write_finish_entry(aw) != c_librarys.ARCHIVE_OK) {
            stateFailed(machine);
            return BackendError.ArchiveExtractFailed;
        }
    }

    return stateReadingMeta(machine);
}

fn stateReadingMeta(machine: *Machine) anyerror!void {
    try machine.enter(.reading_meta);

    const pkginfo_path = try std.fs.path.join(
        machine.allocator,
        &.{ machine.request.out_path, ".PKGINFO" },
    );
    defer machine.allocator.free(pkginfo_path);

    const content = std.fs.cwd().readFileAlloc(machine.allocator, pkginfo_path, 64 * 1024) catch |err| {
        stateFailed(machine);
        return err;
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

    // Проверяем обязательные поля
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

    return stateDone(machine);
}

fn stateDone(machine: *Machine) anyerror!void {
    try machine.enter(.done);
    std.debug.print("✓ prepared '{s}' {s}\n", .{
        machine.meta.?.name,
        machine.meta.?.version,
    });
}

fn stateFailed(machine: *Machine) void {
    _ = machine.enter(.failed) catch {};
    std.debug.print("✗ backend failed, path: ", .{});
    for (machine.stack.items) |s| std.debug.print("{s} ", .{@tagName(s)});
    std.debug.print("\n", .{});
}
