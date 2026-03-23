const std = @import("std");

const states = @import("states.zig");

const database = @import("upac-database");
const PackageMeta = database.PackageMeta;
const PackageFiles = database.PackageFiles;

pub const c_libs = @cImport({
    @cInclude("ostree.h");
    @cInclude("glib.h");
    @cInclude("gio/gio.h");
    @cInclude("fcntl.h");
});

// ── Типы FSM ────────────────────────────────────────────────────────────
pub const StateId = enum {
    opening_repo,
    building_message,
    committing,
    done,
    failed,
};

pub const OstreeOperation = enum {
    install,
    remove,
    manual,

    pub fn toString(self: OstreeOperation) []const u8 {
        return switch (self) {
            .install => "install",
            .remove => "remove",
            .manual => "manual",
        };
    }
};

pub const CommitMachine = struct {
    request: OstreeCommitRequest,
    stack: std.ArrayList(StateId),
    retries: u8,
    max_retries: u8,
    allocator: std.mem.Allocator,
    repo: ?*c_libs.OstreeRepo,
    subject: ?[]u8,
    body: ?[]u8,

    pub fn enter(self: *CommitMachine, id: StateId) !void {
        try self.stack.append(id);
        std.debug.print("[ostree → {s}]\n", .{@tagName(id)});
    }

    pub fn exhausted(self: *CommitMachine) bool {
        return self.retries >= self.max_retries;
    }

    pub fn deinit(self: *CommitMachine) void {
        self.stack.deinit();
        if (self.subject) |string| self.allocator.free(string);
        if (self.body) |string| self.allocator.free(string);
        if (self.repo) |repo| c_libs.g_object_unref(repo);
    }
};

// ── Публичные типы ────────────────────────────────────────────────────────────
pub const CommitEntry = struct {
    checksum: []const u8,
    subject: []const u8,
};

pub const OstreeCommitRequest = struct {
    repo_path: []const u8,
    content_path: []const u8,
    branch: []const u8,
    operation: OstreeOperation,
    packages: []const PackageMeta,
    database_path: []const u8,
};

pub const DiffEntry = struct {
    path: []const u8,
    kind: DiffKind,
};

pub const DiffKind = enum { added, removed, modified };

pub const OstreeError = error{
    RepoOpenFailed,
    CommitFailed,
    DiffFailed,
    RollbackFailed,
    NoPreviousCommit,
    Unexpected,
};

// ── Публичное API ─────────────────────────────────────────────────────────────
pub fn commit(request: OstreeCommitRequest, allocator: std.mem.Allocator) !void {
    var machine = CommitMachine{
        .request = request,
        .stack = std.ArrayList(StateId).init(allocator),
        .retries = 0,
        .max_retries = 2,
        .allocator = allocator,
        .repo = null,
        .subject = null,
        .body = null,
    };
    defer machine.deinit();

    try states.stateOpeningRepo(&machine);
}

// ── Вспомогательная: checkout коммита во временную директорию ─────────────────
fn checkoutRef(c_ostree_repo: *c_libs.OstreeRepo, ref: [:0]const u8, destination_path: [:0]const u8) !void {
    var global_struct_glib_err: ?*c_libs.GError = null;

    var commit_checksum: [*c]u8 = null;
    defer if (commit_checksum) |checksum| c_libs.g_free(checksum);

    if (c_libs.ostree_repo_resolve_rev(c_ostree_repo, ref.ptr, 0, &commit_checksum, &global_struct_glib_err) == 0) {
        if (global_struct_glib_err) |struct_glib_err| c_libs.g_error_free(struct_glib_err);
        return OstreeError.DiffFailed;
    }

    std.fs.makeDirAbsolute(destination_path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    var options = std.mem.zeroes(c_libs.OstreeRepoCheckoutAtOptions);
    options.mode = c_libs.OSTREE_REPO_CHECKOUT_MODE_NONE;
    options.overwrite_mode = c_libs.OSTREE_REPO_CHECKOUT_OVERWRITE_UNION_FILES;

    if (c_libs.ostree_repo_checkout_at(
        c_ostree_repo,
        &options,
        std.c.AT.FDCWD,
        destination_path.ptr,
        commit_checksum,
        null,
        &global_struct_glib_err,
    ) == 0) {
        if (global_struct_glib_err) |struct_glib_err| c_libs.g_error_free(struct_glib_err);
        return OstreeError.DiffFailed;
    }
}

// ── Прямые операции (без FSM) ─────────────────────────────────────────────────
pub fn diff(repo_path: []const u8, from_ref: []const u8, to_ref: []const u8, allocator: std.mem.Allocator) ![]DiffEntry {
    const repo_path_c = try std.fmt.allocPrintZ(allocator, "{s}", .{repo_path});
    defer allocator.free(repo_path_c);

    const g_repo_file = c_libs.g_file_new_for_path(repo_path_c.ptr);
    defer c_libs.g_object_unref(g_repo_file);

    var global_struct_glib_err: ?*c_libs.GError = null;
    const c_ostree_repo = c_libs.ostree_repo_new(g_repo_file);
    defer c_libs.g_object_unref(c_ostree_repo);

    if (c_libs.ostree_repo_open(c_ostree_repo, null, &global_struct_glib_err) == 0) {
        if (global_struct_glib_err) |struct_glib_err| c_libs.g_error_free(struct_glib_err);
        return OstreeError.RepoOpenFailed;
    }

    // Временные директории для checkout
    const timestamp = std.time.milliTimestamp();

    const from_checkout_path = try std.fmt.allocPrintZ(allocator, "/tmp/upac_diff_from_{d}", .{timestamp});
    defer allocator.free(from_checkout_path);
    defer std.fs.deleteTreeAbsolute(from_checkout_path) catch {};

    const to_checkout_path = try std.fmt.allocPrintZ(allocator, "/tmp/upac_diff_to_{d}", .{timestamp + 1});
    defer allocator.free(to_checkout_path);
    defer std.fs.deleteTreeAbsolute(to_checkout_path) catch {};

    const from_ref_c = try std.fmt.allocPrintZ(allocator, "{s}", .{from_ref});
    defer allocator.free(from_ref_c);
    const to_ref_c = try std.fmt.allocPrintZ(allocator, "{s}", .{to_ref});
    defer allocator.free(to_ref_c);

    try checkoutRef(c_ostree_repo.?, from_ref_c, from_checkout_path);
    try checkoutRef(c_ostree_repo.?, to_ref_c, to_checkout_path);

    const from_checkout_file = c_libs.g_file_new_for_path(from_checkout_path.ptr);
    defer c_libs.g_object_unref(from_checkout_file);
    const to_checkout_file = c_libs.g_file_new_for_path(to_checkout_path.ptr);
    defer c_libs.g_object_unref(to_checkout_file);

    const modified_entries = c_libs.g_ptr_array_new();
    const removed_entries = c_libs.g_ptr_array_new();
    const added_entries = c_libs.g_ptr_array_new();
    defer c_libs.g_ptr_array_unref(modified_entries);
    defer c_libs.g_ptr_array_unref(removed_entries);
    defer c_libs.g_ptr_array_unref(added_entries);

    if (c_libs.ostree_diff_dirs(
        c_libs.OSTREE_DIFF_FLAGS_NONE,
        from_checkout_file,
        to_checkout_file,
        modified_entries,
        removed_entries,
        added_entries,
        null,
        &global_struct_glib_err,
    ) == 0) {
        if (global_struct_glib_err) |struct_glib_err| c_libs.g_error_free(struct_glib_err);
        return OstreeError.DiffFailed;
    }

    var diff_entries = std.ArrayList(DiffEntry).init(allocator);
    errdefer {
        for (diff_entries.items) |entry| allocator.free(entry.path);
        diff_entries.deinit();
    }

    var index: usize = 0;
    while (index < added_entries.*.len) : (index += 1) {
        const diff_item: *c_libs.OstreeDiffItem = @ptrCast(@alignCast(added_entries.*.pdata[index]));
        const file_path = std.mem.span(@as([*:0]u8, @ptrCast(c_libs.g_file_get_path(diff_item.target))));
        try diff_entries.append(.{ .path = try allocator.dupe(u8, file_path), .kind = .added });
    }

    index = 0;
    while (index < removed_entries.*.len) : (index += 1) {
        const diff_item: *c_libs.OstreeDiffItem = @ptrCast(@alignCast(removed_entries.*.pdata[index]));
        const file_path = std.mem.span(@as([*:0]u8, @ptrCast(c_libs.g_file_get_path(diff_item.src))));
        try diff_entries.append(.{ .path = try allocator.dupe(u8, file_path), .kind = .removed });
    }

    index = 0;
    while (index < modified_entries.*.len) : (index += 1) {
        const diff_item: *c_libs.OstreeDiffItem = @ptrCast(@alignCast(modified_entries.*.pdata[index]));
        const file_path = std.mem.span(@as([*:0]u8, @ptrCast(c_libs.g_file_get_path(diff_item.target))));
        try diff_entries.append(.{ .path = try allocator.dupe(u8, file_path), .kind = .modified });
    }

    return diff_entries.toOwnedSlice();
}

pub fn listCommits(repo_path: []const u8, branch: []const u8, allocator: std.mem.Allocator) ![]CommitEntry {
    const repo_path_c = try std.fmt.allocPrintZ(allocator, "{s}", .{repo_path});
    defer allocator.free(repo_path_c);

    const branch_c = try std.fmt.allocPrintZ(allocator, "{s}", .{branch});
    defer allocator.free(branch_c);

    const g_repo_file = c_libs.g_file_new_for_path(repo_path_c.ptr);
    defer c_libs.g_object_unref(g_repo_file);

    var global_glib_err: ?*c_libs.GError = null;
    const c_ostree_repo = c_libs.ostree_repo_new(g_repo_file);
    defer c_libs.g_object_unref(c_ostree_repo);

    if (c_libs.ostree_repo_open(c_ostree_repo, null, &global_glib_err) == 0) {
        if (global_glib_err) |err| c_libs.g_error_free(err);
        return OstreeError.RepoOpenFailed;
    }

    var entries = std.ArrayList(CommitEntry).init(allocator);
    errdefer {
        for (entries.items) |entry| {
            allocator.free(entry.checksum);
            allocator.free(entry.subject);
        }
        entries.deinit();
    }

    var current_checksum: [*c]u8 = null;
    defer if (current_checksum) |cs| c_libs.g_free(cs);

    if (c_libs.ostree_repo_resolve_rev(c_ostree_repo, branch_c.ptr, 0, &current_checksum, &global_glib_err) == 0) {
        if (global_glib_err) |err| c_libs.g_error_free(err);
        return entries.toOwnedSlice();
    }

    var checksum = current_checksum;
    while (checksum != null) {
        var commit_variant: ?*c_libs.GVariant = null;
        defer if (commit_variant) |variant| c_libs.g_variant_unref(variant);

        if (c_libs.ostree_repo_load_variant(
            c_ostree_repo,
            c_libs.OSTREE_OBJECT_TYPE_COMMIT,
            checksum,
            &commit_variant,
            &global_glib_err,
        ) == 0) {
            if (global_glib_err) |err| c_libs.g_error_free(err);
            break;
        }

        var subject_variant: ?*c_libs.GVariant = null;
        defer if (subject_variant) |variant| c_libs.g_variant_unref(variant);

        subject_variant = c_libs.g_variant_get_child_value(commit_variant, 3);
        var subject_len: usize = 0;

        const subject_ptr = c_libs.g_variant_get_string(subject_variant, &subject_len);
        const subject_str = subject_ptr[0..subject_len];
        const checksum_str = std.mem.span(@as([*:0]const u8, @ptrCast(checksum)));

        try entries.append(CommitEntry{
            .checksum = try allocator.dupe(u8, checksum_str),
            .subject = try allocator.dupe(u8, subject_str),
        });

        const parent = c_libs.ostree_commit_get_parent(commit_variant);
        checksum = parent;
    }

    return entries.toOwnedSlice();
}

pub fn refresh(repo_path: []const u8, content_path: []const u8, root_path: []const u8, branch: []const u8, database_path: []const u8, allocator: std.mem.Allocator) !void {
    const repo_path_c = try std.fmt.allocPrintZ(allocator, "{s}", .{repo_path});
    defer allocator.free(repo_path_c);

    const branch_c = try std.fmt.allocPrintZ(allocator, "{s}", .{branch});
    defer allocator.free(branch_c);

    const g_repo_file = c_libs.g_file_new_for_path(repo_path_c.ptr);
    defer c_libs.g_object_unref(g_repo_file);

    var global_glib_err: ?*c_libs.GError = null;
    const c_ostree_repo = c_libs.ostree_repo_new(g_repo_file);
    defer c_libs.g_object_unref(c_ostree_repo);

    if (c_libs.ostree_repo_open(c_ostree_repo, null, &global_glib_err) == 0) {
        if (global_glib_err) |err| c_libs.g_error_free(err);
        return OstreeError.RepoOpenFailed;
    }

    var current_checksum: [*c]u8 = null;
    defer if (current_checksum) |cs| c_libs.g_free(cs);

    if (c_libs.ostree_repo_resolve_rev(c_ostree_repo, branch_c.ptr, 0, &current_checksum, &global_glib_err) == 0) {
        if (global_glib_err) |err| c_libs.g_error_free(err);
        return OstreeError.NoPreviousCommit;
    }

    var commit_variant: ?*c_libs.GVariant = null;
    defer if (commit_variant) |v| c_libs.g_variant_unref(v);

    if (c_libs.ostree_repo_load_variant(
        c_ostree_repo,
        c_libs.OSTREE_OBJECT_TYPE_COMMIT,
        current_checksum,
        &commit_variant,
        &global_glib_err,
    ) == 0) {
        if (global_glib_err) |err| c_libs.g_error_free(err);
        return OstreeError.RollbackFailed;
    }

    var body_variant: ?*c_libs.GVariant = null;
    defer if (body_variant) |v| c_libs.g_variant_unref(v);
    body_variant = c_libs.g_variant_get_child_value(commit_variant, 4);

    var body_len: usize = 0;
    const body_ptr = c_libs.g_variant_get_string(body_variant, &body_len);
    const body = body_ptr[0..body_len];

    const commit_packages = try parseBodyPackages(allocator, body);
    defer {
        for (commit_packages) |pkg| {
            allocator.free(pkg.name);
            allocator.free(pkg.version);
            allocator.free(pkg.author);
            allocator.free(pkg.description);
            allocator.free(pkg.license);
            allocator.free(pkg.url);
            allocator.free(pkg.checksum);
        }
        allocator.free(commit_packages);
    }

    const current_packages = try database.listPackages(database_path, allocator);
    defer {
        for (current_packages) |name| allocator.free(name);
        allocator.free(current_packages);
    }

    // Удаляем из БД пакеты которых нет в коммите
    for (current_packages) |current_name| {
        const exists_in_commit = for (commit_packages) |pkg| {
            if (std.mem.eql(u8, pkg.name, current_name)) break true;
        } else false;

        if (!exists_in_commit) {
            try database.removePackage(database_path, current_name, allocator);
        }
    }

    for (commit_packages) |pkg| {
        const exists_in_db = for (current_packages) |current_name| {
            if (std.mem.eql(u8, pkg.name, current_name)) break true;
        } else false;

        if (!exists_in_db) {
            const package_repo_path = try std.fs.path.join(
                allocator,
                &.{ content_path, pkg.name },
            );
            defer allocator.free(package_repo_path);

            var file_paths = std.ArrayList([]const u8).init(allocator);
            defer {
                for (file_paths.items) |fp| allocator.free(fp);
                file_paths.deinit();
            }

            collectFiles(allocator, package_repo_path, &file_paths) catch {};

            const package_files = PackageFiles{
                .name = pkg.name,
                .paths = file_paths.items,
            };

            try database.addPackage(database_path, pkg, package_files, allocator);
        }
    }

    try refreshHardlinks(allocator, content_path, root_path);
}

pub fn rollback(repo_path: []const u8, content_path: []const u8, branch: []const u8, allocator: std.mem.Allocator) !void {
    const repo_path_c = try std.fmt.allocPrintZ(allocator, "{s}", .{repo_path});
    defer allocator.free(repo_path_c);

    const content_path_c = try std.fmt.allocPrintZ(allocator, "{s}", .{content_path});
    defer allocator.free(content_path_c);

    const branch_c = try std.fmt.allocPrintZ(allocator, "{s}", .{branch});
    defer allocator.free(branch_c);

    const g_repo_file = c_libs.g_file_new_for_path(repo_path_c.ptr);
    defer c_libs.g_object_unref(g_repo_file);

    var global_struct_glib_err: ?*c_libs.GError = null;
    const struct_ostree_repo = c_libs.ostree_repo_new(g_repo_file);
    defer c_libs.g_object_unref(struct_ostree_repo);

    if (c_libs.ostree_repo_open(struct_ostree_repo, null, &global_struct_glib_err) == 0) {
        if (global_struct_glib_err) |struct_glib_err| c_libs.g_error_free(struct_glib_err);
        return OstreeError.RepoOpenFailed;
    }

    var current_checksum: [*c]u8 = null;
    defer if (current_checksum) |checksum| c_libs.g_free(checksum);

    if (c_libs.ostree_repo_resolve_rev(struct_ostree_repo, branch_c.ptr, 0, &current_checksum, &global_struct_glib_err) == 0) {
        if (global_struct_glib_err) |struct_glib_err| c_libs.g_error_free(struct_glib_err);
        return OstreeError.NoPreviousCommit;
    }

    var commit_variant: ?*c_libs.GVariant = null;
    defer if (commit_variant) |v| c_libs.g_variant_unref(v);

    if (c_libs.ostree_repo_load_variant(
        struct_ostree_repo,
        c_libs.OSTREE_OBJECT_TYPE_COMMIT,
        current_checksum,
        &commit_variant,
        &global_struct_glib_err,
    ) == 0) {
        if (global_struct_glib_err) |struct_glib_err| c_libs.g_error_free(struct_glib_err);
        return OstreeError.RollbackFailed;
    }

    const parent_checksum = c_libs.ostree_commit_get_parent(commit_variant);
    if (parent_checksum == null) return OstreeError.NoPreviousCommit;

    var options = std.mem.zeroes(c_libs.OstreeRepoCheckoutAtOptions);
    options.mode = c_libs.OSTREE_REPO_CHECKOUT_MODE_NONE;
    options.overwrite_mode = c_libs.OSTREE_REPO_CHECKOUT_OVERWRITE_UNION_FILES;

    if (c_libs.ostree_repo_checkout_at(
        struct_ostree_repo,
        &options,
        std.c.AT.FDCWD,
        content_path_c.ptr,
        parent_checksum,
        null,
        &global_struct_glib_err,
    ) == 0) {
        if (global_struct_glib_err) |struct_glib_err| c_libs.g_error_free(struct_glib_err);
        return OstreeError.RollbackFailed;
    }

    if (c_libs.ostree_repo_prepare_transaction(struct_ostree_repo, null, null, &global_struct_glib_err) == 0) {
        if (global_struct_glib_err) |struct_glib_err| c_libs.g_error_free(struct_glib_err);
        return OstreeError.RollbackFailed;
    }

    c_libs.ostree_repo_transaction_set_ref(struct_ostree_repo, null, branch_c.ptr, parent_checksum);

    if (c_libs.ostree_repo_commit_transaction(struct_ostree_repo, null, null, &global_struct_glib_err) == 0) {
        if (global_struct_glib_err) |struct_glib_err| c_libs.g_error_free(struct_glib_err);
        _ = c_libs.ostree_repo_abort_transaction(struct_ostree_repo, null, null);
        return OstreeError.RollbackFailed;
    }
}

// ── Вспомогательные функции ───────────────────────────────────────────────────
fn parseBodyPackages(allocator: std.mem.Allocator, body: []const u8) ![]PackageMeta {
    var packages = std.ArrayList(PackageMeta).init(allocator);
    errdefer {
        for (packages.items) |pkg| {
            allocator.free(pkg.name);
            allocator.free(pkg.version);
            allocator.free(pkg.author);
            allocator.free(pkg.description);
            allocator.free(pkg.license);
            allocator.free(pkg.url);
            allocator.free(pkg.checksum);
        }
        packages.deinit();
    }

    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "pkg ")) continue;

        const pkg_line = line[4..];
        var package_meta = PackageMeta{
            .name = "",
            .version = "",
            .author = "",
            .description = "",
            .license = "",
            .url = "",
            .installed_at = 0,
            .checksum = "",
        };
        var name_owned = false;
        var version_owned = false;
        var author_owned = false;
        var description_owned = false;
        var license_owned = false;
        var url_owned = false;
        var checksum_owned = false;

        errdefer {
            if (name_owned) allocator.free(package_meta.name);
            if (version_owned) allocator.free(package_meta.version);
            if (author_owned) allocator.free(package_meta.author);
            if (description_owned) allocator.free(package_meta.description);
            if (license_owned) allocator.free(package_meta.license);
            if (url_owned) allocator.free(package_meta.url);
            if (checksum_owned) allocator.free(package_meta.checksum);
        }

        var fields = std.mem.splitScalar(u8, pkg_line, ' ');
        while (fields.next()) |field| {
            const equals_position = std.mem.indexOfScalar(u8, field, '=') orelse continue;
            const key = field[0..equals_position];
            const value = field[equals_position + 1 ..];

            if (std.mem.eql(u8, key, "name")) {
                package_meta.name = try allocator.dupe(u8, value);
                name_owned = true;
            } else if (std.mem.eql(u8, key, "version")) {
                package_meta.version = try allocator.dupe(u8, value);
                version_owned = true;
            } else if (std.mem.eql(u8, key, "author")) {
                package_meta.author = try allocator.dupe(u8, value);
                author_owned = true;
            } else if (std.mem.eql(u8, key, "description")) {
                package_meta.description = try allocator.dupe(u8, value);
                description_owned = true;
            } else if (std.mem.eql(u8, key, "license")) {
                package_meta.license = try allocator.dupe(u8, value);
                license_owned = true;
            } else if (std.mem.eql(u8, key, "url")) {
                package_meta.url = try allocator.dupe(u8, value);
                url_owned = true;
            } else if (std.mem.eql(u8, key, "installed_at")) {
                package_meta.installed_at = std.fmt.parseInt(i64, value, 10) catch 0;
            } else if (std.mem.eql(u8, key, "checksum")) {
                package_meta.checksum = try allocator.dupe(u8, value);
                checksum_owned = true;
            }
        }

        if (package_meta.name.len > 0) {
            try packages.append(package_meta);
        }
    }

    return packages.toOwnedSlice();
}

fn refreshHardlinks(
    allocator: std.mem.Allocator,
    content_path: []const u8,
    root_path: []const u8,
) !void {
    var content_dir = try std.fs.openDirAbsolute(content_path, .{ .iterate = true });
    defer content_dir.close();

    var content_dir_iterator = content_dir.iterate();
    while (try content_dir_iterator.next()) |entry| {
        if (entry.kind != .directory) continue;

        const package_path = try std.fs.path.join(allocator, &.{ content_path, entry.name });
        defer allocator.free(package_path);

        try hardlinkTree(allocator, package_path, root_path);
    }
}

fn collectFiles(allocator: std.mem.Allocator, path: []const u8, files_path_list: *std.ArrayList([]const u8)) !void {
    var directory = try std.fs.openDirAbsolute(path, .{ .iterate = true });
    defer directory.close();

    var directory_iterator = directory.iterate();
    while (try directory_iterator.next()) |entry| {
        const entry_path_with_name = try std.fs.path.join(allocator, &.{ path, entry.name });
        switch (entry.kind) {
            .directory => {
                defer allocator.free(entry_path_with_name);
                try collectFiles(allocator, entry_path_with_name, files_path_list);
            },
            .file, .sym_link => try files_path_list.append(entry_path_with_name),
            else => allocator.free(entry_path_with_name),
        }
    }
}

fn hardlinkTree(allocator: std.mem.Allocator, source_path: []const u8, destination_path: []const u8) !void {
    var source_dir = try std.fs.openDirAbsolute(source_path, .{ .iterate = true });
    defer source_dir.close();

    var source_dir_iter = source_dir.iterate();
    while (try source_dir_iter.next()) |entry| {
        const source_entry_path = try std.fs.path.join(allocator, &.{ source_path, entry.name });
        defer allocator.free(source_entry_path);

        const destination_entry_path = try std.fs.path.join(allocator, &.{ destination_path, entry.name });
        defer allocator.free(destination_entry_path);

        switch (entry.kind) {
            .directory => {
                std.fs.makeDirAbsolute(destination_entry_path) catch |err| switch (err) {
                    error.PathAlreadyExists => {},
                    else => return err,
                };
                try hardlinkTree(allocator, source_entry_path, destination_entry_path);
            },
            .file => {
                std.fs.deleteFileAbsolute(destination_entry_path) catch {};
                try std.posix.link(source_entry_path, destination_entry_path, 0);
            },
            else => {},
        }
    }
}
