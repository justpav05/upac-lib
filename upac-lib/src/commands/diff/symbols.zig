// ── Imports ─────────────────────────────────────────────────────────────────────
const diff = @import("diff.zig");
const std = diff.std;
const c_libs = diff.c_libs;
const data = diff.data;

const CSlice = diff.ffi.CSlice;

const CPackageMeta = diff.ffi.CPackageMeta;
const CPackageMetaArray = diff.ffi.CPackageMetaArray;

const CPackageDiffArray = diff.ffi.CPackageDiffArray;
const CPackageDiffEntry = diff.ffi.CPackageDiffEntry;

const CAttributedDiffArray = diff.ffi.CAttributedDiffArray;
const CAttributedDiffEntry = diff.ffi.CAttributedDiffEntry;

const CCommitArray = diff.ffi.CCommitArray;
const CCommitEntry = diff.ffi.CCommitEntry;

const ErrorCode = diff.ffi.ErrorCode;
const Operation = diff.ffi.Operation;
const fromError = diff.ffi.fromError;

const rollback = diff.rollback;

pub export fn upac_diff_packages(repo_path_c: CSlice, from_ref_c: CSlice, to_ref_c: CSlice, out_c: *CPackageDiffArray) callconv(.C) i32 {
    const allocator = diff.ffi.allocator();

    const pkg_entries = diff.diffPackages(
        repo_path_c.toSlice(),
        from_ref_c.toSlice(),
        to_ref_c.toSlice(),
        allocator,
    ) catch |err| return @intFromEnum(fromError(err, Operation.diff));

    const entries_c = allocator.alloc(CPackageDiffEntry, pkg_entries.len) catch {
        for (pkg_entries) |entry| allocator.free(entry.name);
        allocator.free(pkg_entries);
        return @intFromEnum(ErrorCode.out_of_memory);
    };

    for (entries_c, 0..) |*entry_c, index| {
        entry_c.* = .{
            .name = CSlice.fromSlice(pkg_entries[index].name),
            .kind = switch (pkg_entries[index].kind) {
                .added => .added,
                .removed => .removed,
                .updated => .updated,
            },
        };
    }
    allocator.free(pkg_entries);

    out_c.* = .{ .ptr = entries_c.ptr, .len = entries_c.len };
    return @intFromEnum(ErrorCode.ok);
}

pub export fn upac_diff_packages_free(c_out: *CPackageDiffArray) callconv(.C) void {
    const allocator = diff.ffi.allocator();
    const entries = c_out.toSlice();
    for (entries) |entry| allocator.free(entry.name.toSlice());
    allocator.free(entries);
}

pub export fn upac_diff_files_attributed(repo_path_c: CSlice, from_ref_c: CSlice, to_ref_c: CSlice, root_path_c: CSlice, db_path_c: CSlice, out_c: *CAttributedDiffArray) callconv(.C) i32 {
    const allocator = diff.ffi.allocator();

    const entries = diff.diffFilesAttributed(
        repo_path_c.toSlice(),
        from_ref_c.toSlice(),
        to_ref_c.toSlice(),
        root_path_c.toSlice(),
        db_path_c.toSlice(),
        allocator,
    ) catch |err| return @intFromEnum(fromError(err, Operation.diff));

    const entries_c = allocator.alloc(CAttributedDiffEntry, entries.len) catch {
        for (entries) |entry| {
            allocator.free(entry.path);
            allocator.free(entry.package_name);
        }
        allocator.free(entries);
        return @intFromEnum(ErrorCode.out_of_memory);
    };

    for (entries_c, 0..) |*entry_c, index| {
        entry_c.* = .{
            .path = CSlice.fromSlice(entries[index].path),
            .kind = @enumFromInt(@intFromEnum(entries[index].kind)),
            .package_name = CSlice.fromSlice(entries[index].package_name),
        };
    }
    allocator.free(entries);

    out_c.* = .{ .ptr = entries_c.ptr, .len = entries_c.len };
    return @intFromEnum(ErrorCode.ok);
}

pub export fn upac_diff_files_attributed_free(out_c: *CAttributedDiffArray) callconv(.C) void {
    const allocator = diff.ffi.allocator();
    const entries = out_c.toSlice();
    for (entries) |entry| {
        allocator.free(entry.path.toSlice());
        allocator.free(entry.package_name.toSlice());
    }
    allocator.free(entries);
}

pub export fn upac_list_packages(c_repo_path: CSlice, c_branch: CSlice, c_db_path: CSlice, c_out: *CPackageMetaArray) callconv(.C) i32 {
    const allocator = diff.ffi.allocator();

    var gerror: ?*c_libs.GError = null;
    defer if (gerror) |err| c_libs.g_error_free(err);

    const repo_path_c = std.fmt.allocPrintZ(allocator, "{s}", .{c_repo_path.toSlice()}) catch
        return @intFromEnum(ErrorCode.out_of_memory);
    defer allocator.free(repo_path_c);

    const branch_c = std.fmt.allocPrintZ(allocator, "{s}", .{c_branch.toSlice()}) catch
        return @intFromEnum(ErrorCode.out_of_memory);
    defer allocator.free(branch_c);

    const gfile = c_libs.g_file_new_for_path(repo_path_c.ptr);
    defer c_libs.g_object_unref(gfile);

    const repo = c_libs.ostree_repo_new(gfile);
    defer c_libs.g_object_unref(repo);

    if (c_libs.ostree_repo_open(repo, null, &gerror) == 0) {
        return @intFromEnum(ErrorCode.ostree_repo_open_failed);
    }

    var head_checksum: ?[*:0]u8 = null;
    if (c_libs.ostree_repo_resolve_rev(repo, branch_c.ptr, 1, &head_checksum, null) == 0 or head_checksum == null) {
        c_out.* = .{ .ptr = undefined, .len = 0 };
        return @intFromEnum(ErrorCode.ok);
    }
    defer c_libs.g_free(@ptrCast(head_checksum));

    var commit_variant: ?*c_libs.GVariant = null;
    defer if (commit_variant) |variant| c_libs.g_variant_unref(variant);

    if (c_libs.ostree_repo_load_variant(repo, c_libs.OSTREE_OBJECT_TYPE_COMMIT, head_checksum, &commit_variant, &gerror) == 0) return @intFromEnum(ErrorCode.ostree_repo_open_failed);

    var body_variant: ?*c_libs.GVariant = null;
    defer if (body_variant) |variant| c_libs.g_variant_unref(variant);

    body_variant = c_libs.g_variant_get_child_value(commit_variant, 4);

    var body_len: usize = 0;
    const body_ptr = c_libs.g_variant_get_string(body_variant, &body_len);
    const body = body_ptr[0..body_len];

    var meta_list = std.ArrayList(CPackageMeta).init(allocator);
    errdefer {
        for (meta_list.items) |*item| freeCPackageMeta(item, allocator);
        meta_list.deinit();
    }

    var line_iter = std.mem.splitScalar(u8, body, '\n');
    while (line_iter.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;

        const space_index = std.mem.indexOfScalar(u8, trimmed, ' ') orelse continue;
        const pkg_checksum = std.mem.trim(u8, trimmed[space_index + 1 ..], " \t");

        const package_meta = data.readMeta(c_db_path.toSlice(), pkg_checksum, allocator) catch continue;

        meta_list.append(.{
            .name = CSlice.fromSlice(package_meta.name),
            .version = CSlice.fromSlice(package_meta.version),
            .author = CSlice.fromSlice(package_meta.author),
            .description = CSlice.fromSlice(package_meta.description),
            .license = CSlice.fromSlice(package_meta.license),
            .url = CSlice.fromSlice(package_meta.url),
            .installed_at = package_meta.installed_at,
            .checksum = CSlice.fromSlice(package_meta.checksum),
        }) catch return @intFromEnum(ErrorCode.out_of_memory);
    }

    const slice = meta_list.toOwnedSlice() catch
        return @intFromEnum(ErrorCode.out_of_memory);

    c_out.* = .{ .ptr = slice.ptr, .len = slice.len };
    return @intFromEnum(ErrorCode.ok);
}

fn freeCPackageMeta(meta: *CPackageMeta, allocator: std.mem.Allocator) void {
    allocator.free(meta.name.toSlice());
    allocator.free(meta.version.toSlice());
    allocator.free(meta.author.toSlice());
    allocator.free(meta.description.toSlice());
    allocator.free(meta.license.toSlice());
    allocator.free(meta.url.toSlice());
    allocator.free(meta.checksum.toSlice());
}

pub export fn upac_packages_free(package_meta_array_c: *CPackageMetaArray) callconv(.C) void {
    const allocator = diff.ffi.allocator();
    const entries = package_meta_array_c.toSlice();

    for (entries) |*entry| freeCPackageMeta(entry, allocator);
    allocator.free(entries);
}

// Generates a list of commits for a specified branch. Converts internal commit records into a C-compatible format
pub export fn upac_list_commits(repo_path_c: CSlice, branch_c: CSlice, c_commits: *CCommitArray) callconv(.C) i32 {
    const allocator = diff.ffi.allocator();

    const commit_entries = rollback.listCommits(
        repo_path_c.toSlice(),
        branch_c.toSlice(),
        allocator,
    ) catch |err| return @intFromEnum(fromError(err, Operation.list));

    const c_commit_entries = allocator.alloc(CCommitEntry, commit_entries.len) catch {
        for (commit_entries) |entry| {
            allocator.free(entry.checksum);
            allocator.free(entry.subject);
        }
        allocator.free(commit_entries);
        return @intFromEnum(ErrorCode.out_of_memory);
    };

    for (commit_entries, 0..) |entry, index| {
        c_commit_entries[index] = .{
            .checksum = CSlice.fromSlice(entry.checksum),
            .subject = CSlice.fromSlice(entry.subject),
        };
    }
    allocator.free(commit_entries);

    c_commits.* = .{ .ptr = c_commit_entries.ptr, .len = c_commit_entries.len };
    return @intFromEnum(ErrorCode.ok);
}

// A function for cleaning up memory after retrieving the list of commits; it frees the checksum and header strings
pub export fn upac_commits_free(c_commits: *CCommitArray) callconv(.C) void {
    const allocator = diff.ffi.allocator();
    const entries = c_commits.toSlice();
    for (entries) |entry| {
        allocator.free(entry.checksum.toSlice());
        allocator.free(entry.subject.toSlice());
    }
    allocator.free(entries);
}
