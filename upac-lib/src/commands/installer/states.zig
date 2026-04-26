// ── Imports ─────────────────────────────────────────────────────────────────────
const std = @import("std");

const data = @import("upac-data");

const installer = @import("installer.zig");
const c_libs = installer.c_libs;

const InstallerMachine = installer.InstallerMachine;
const InstallerError = installer.InstallerError;

const utils = @import("utils.zig");
const dirSize = utils.dirSize;
const collectFileChecksums = utils.collectFileChecksums;
const estimateCheckoutSize = utils.estimateCheckoutSize;

// ── InstallerFSM states ─────────────────────────────────────────────────────────────────
// It verifies the physical existence of the temporary package folder and the repository path. If the paths do not exist, the installation is immediately aborted
pub fn stateVerifying(machine: *InstallerMachine) InstallerError!void {
    machine.enter(.verifying) catch return InstallerError.OutOfMemory;

    for (machine.data.packages) |entry| try machine.check(std.fs.accessAbsolute(entry.temp_path, .{}), InstallerError.PathNotFound);

    try machine.check(std.fs.accessAbsoluteZ(machine.data.root_path, .{}), InstallerError.PathNotFound);
    try machine.check(std.fs.accessAbsoluteZ(machine.data.repo_path, .{}), InstallerError.PathNotFound);

    const prefix_directory = try machine.check(std.fs.path.join(machine.allocator, &.{ std.mem.span(machine.data.root_path), std.mem.span(machine.data.prefix_path) }), InstallerError.AllocZFailed);
    defer machine.allocator.free(prefix_directory);

    try machine.check(std.fs.accessAbsolute(prefix_directory, .{}), InstallerError.PathNotFound);

    machine.resetRetries();
    return stateCheckSpace(machine);
}

fn stateCheckSpace(machine: *InstallerMachine) InstallerError!void {
    machine.enter(.check_space) catch return InstallerError.OutOfMemory;

    var new_packages_size: u64 = 0;
    for (machine.data.packages) |entry| new_packages_size += try machine.check(dirSize(machine.allocator, entry.temp_path), InstallerError.CheckSpaceFailed);

    const prefix_path = try machine.check(std.fs.path.join(machine.allocator, &.{ std.mem.span(machine.data.root_path), std.mem.span(machine.data.prefix_path) }), InstallerError.CheckSpaceFailed);
    defer machine.allocator.free(prefix_path);

    const existing_prefix_size = dirSize(machine.allocator, prefix_path) catch 0;
    const required = existing_prefix_size + new_packages_size * 2;

    var stat: c_libs.struct_statvfs = undefined;
    if (c_libs.statvfs(machine.data.root_path, &stat) != 0) {
        stateFailed(machine);
        return InstallerError.CheckSpaceFailed;
    }

    const available: u64 = @as(u64, @intCast(stat.f_bavail)) * @as(u64, @intCast(stat.f_bsize));
    if (required > available) {
        stateFailed(machine);
        return InstallerError.NotEnoughSpace;
    }

    machine.resetRetries();
    return stateOpenRepo(machine);
}

// Initializes an Ostree Repo object. This marks the transition from Zig paths to objects within the OSTree C library
fn stateOpenRepo(machine: *InstallerMachine) InstallerError!void {
    machine.enter(.open_repo) catch return InstallerError.OutOfMemory;

    const gfile = c_libs.g_file_new_for_path(machine.data.repo_path);
    defer c_libs.g_object_unref(@ptrCast(gfile));

    const repo = c_libs.ostree_repo_new(gfile);

    if (c_libs.ostree_repo_open(repo, machine.cancellable, &machine.gerror) == 0) {
        c_libs.g_object_unref(repo);
        return machine.retry(stateOpenRepo);
    }
    machine.repo = repo;

    try machine.gcheck(c_libs.ostree_repo_prepare_transaction(repo, null, machine.cancellable, &machine.gerror), error.RepoTransactionFailed);

    var previos_mtree: ?*c_libs.OstreeMutableTree = null;
    if (c_libs.ostree_repo_resolve_rev(repo, machine.data.branch, 0, &machine.previous_commit_checksum, null) != 0) {
        previos_mtree = c_libs.ostree_mutable_tree_new_from_commit(repo, machine.previous_commit_checksum, &machine.gerror);
        if (previos_mtree == null) {
            if (machine.gerror != null) {
                stateFailed(machine);
                return InstallerError.RepoTransactionFailed;
            }
            previos_mtree = c_libs.ostree_mutable_tree_new();
        }
    } else {
        previos_mtree = c_libs.ostree_mutable_tree_new();
    }

    machine.mtree = previos_mtree;

    machine.resetRetries();
    return stateCheckInstalled(machine);
}

// A function to verify that a package has not been previously installed on the system, in order to prevent undefined behavior
fn stateCheckInstalled(machine: *InstallerMachine) InstallerError!void {
    machine.enter(.check_installed) catch return InstallerError.OutOfMemory;

    const repo = try machine.unwrap(machine.repo, error.RepoOpenFailed);

    var commit_variant: ?*c_libs.GVariant = null;
    defer if (commit_variant) |variant| c_libs.g_variant_unref(variant);

    std.debug.print("{any}", .{machine.previous_commit_checksum == null});

    if (c_libs.ostree_repo_load_variant(repo, c_libs.OSTREE_OBJECT_TYPE_COMMIT, machine.previous_commit_checksum, &commit_variant, &machine.gerror) == 0) {
        machine.resetRetries();
        return stateWriteDatabase(machine);
    }

    std.debug.print("{any}", .{machine.previous_commit_checksum == null});

    var body_variant: ?*c_libs.GVariant = null;
    defer if (body_variant) |variant| c_libs.g_variant_unref(variant);

    body_variant = c_libs.g_variant_get_child_value(commit_variant, 4);

    var body_len: usize = 0;
    const body_ptr = c_libs.g_variant_get_string(body_variant, &body_len);
    const body = body_ptr[0..body_len];

    const current_package_name = machine.data.packages[machine.current_package_index].package.meta.name;

    var split_lines_iter = std.mem.splitScalar(u8, body, '\n');
    while (split_lines_iter.next()) |line| {
        const trimmed_line = std.mem.trim(u8, line, " \t\r");
        if (trimmed_line.len == 0) continue;

        const separator_index = std.mem.indexOfScalar(u8, trimmed_line, ' ') orelse continue;
        const installed_package_name = trimmed_line[0..separator_index];

        if (std.ascii.eqlIgnoreCase(installed_package_name, current_package_name)) {
            stateFailed(machine);
            return InstallerError.AlreadyInstalled;
        }
    }

    machine.resetRetries();
    return stateWriteDatabase(machine);
}

// Once the files have been processed, this function saves the data to the local upac database (.meta and .files) so that the system knows the package is installed
fn stateWriteDatabase(machine: *InstallerMachine) InstallerError!void {
    machine.enter(.write_database) catch return InstallerError.OutOfMemory;

    const current_install_entry = machine.data.packages[machine.current_package_index];

    const relative_database_path = if (std.mem.startsWith(u8, std.mem.span(machine.data.database_path), std.mem.span(machine.data.root_path)))
        std.mem.span(machine.data.database_path)[std.mem.span(machine.data.root_path).len..]
    else
        std.mem.span(machine.data.database_path);

    const staged_database_dir_path = std.fs.path.join(machine.allocator, &.{ current_install_entry.temp_path, relative_database_path }) catch return InstallerError.AllocZFailed;
    defer machine.allocator.free(staged_database_dir_path);

    try machine.check(std.fs.cwd().makePath(staged_database_dir_path), InstallerError.AllocZFailed);

    var file_map = data.FileMap.init(machine.allocator);
    defer data.freeFileMap(&file_map, machine.allocator);

    try machine.check(collectFileChecksums(machine, current_install_entry.temp_path, current_install_entry.temp_path, &file_map), InstallerError.CollectFileChecksumsFailed);

    data.writePackage(staged_database_dir_path, current_install_entry.checksum, current_install_entry.package.meta, file_map, machine.allocator) catch return machine.retry(stateWriteDatabase);

    machine.resetRetries();
    return stateProcessDbFiles(machine);
}

fn stateProcessDbFiles(machine: *InstallerMachine) InstallerError!void {
    try machine.check(machine.enter(.process_db_files), InstallerError.OutOfMemory);

    const repo = try machine.unwrap(machine.repo, InstallerError.RepoOpenFailed);
    const mtree = try machine.unwrap(machine.mtree, InstallerError.RepoOpenFailed);

    const current_install_entry = machine.data.packages[machine.current_package_index];

    const temp_path_c = try machine.check(machine.allocator.dupeZ(u8, current_install_entry.temp_path), InstallerError.AllocZFailed);
    defer machine.allocator.free(temp_path_c);

    if (c_libs.ostree_repo_write_dfd_to_mtree(repo, std.c.AT.FDCWD, temp_path_c.ptr, mtree, null, machine.cancellable, &machine.gerror) == 0) return machine.retry(stateProcessDbFiles);

    machine.current_package_index += 1;
    if (machine.current_package_index < machine.data.packages.len) {
        machine.resetRetries();
        return stateCheckInstalled(machine);
    }

    machine.resetRetries();
    return stateCommit(machine);
}

// It takes an in-memory tree (mtree) and uses it to create an actual commit in the selected branch of an OSTree repository
fn stateCommit(machine: *InstallerMachine) InstallerError!void {
    try machine.check(machine.enter(.commit), InstallerError.OutOfMemory);

    const repo = try machine.unwrap(machine.repo, InstallerError.RepoOpenFailed);
    const mtree = try machine.unwrap(machine.mtree, InstallerError.PackageNotFound);

    // ── Build body ───────────────────────────────────────────────────────────
    var body_alloc = std.Io.Writer.Allocating.init(machine.allocator);
    defer body_alloc.deinit();
    const body_writer = &body_alloc.writer;

    if (machine.previous_commit_checksum != null) {
        var previous_commit: ?*c_libs.GVariant = null;
        defer if (previous_commit) |variant| c_libs.g_variant_unref(variant);

        if (c_libs.ostree_repo_load_variant(repo, c_libs.OSTREE_OBJECT_TYPE_COMMIT, machine.previous_commit_checksum, &previous_commit, &machine.gerror) != 0) {
            var prev_body_variant: ?*c_libs.GVariant = null;
            defer if (prev_body_variant) |variant| c_libs.g_variant_unref(variant);

            prev_body_variant = c_libs.g_variant_get_child_value(previous_commit, 4);

            var prev_body_len: usize = 0;
            const prev_body_ptr = c_libs.g_variant_get_string(prev_body_variant, &prev_body_len);

            try machine.check(body_writer.writeAll(prev_body_ptr[0..prev_body_len]), InstallerError.AllocZFailed);
            if (prev_body_len > 0 and prev_body_ptr[prev_body_len - 1] != '\n') try machine.check(body_writer.writeByte('\n'), InstallerError.AllocZFailed);
        }
    }

    for (machine.data.packages) |entry| try machine.check(body_writer.print("{s} {s}\n", .{ entry.package.meta.name, entry.checksum }), InstallerError.AllocZFailed);

    const body_c = try machine.check(machine.allocator.dupeZ(u8, body_alloc.written()), InstallerError.OutOfMemory);
    defer machine.allocator.free(body_c);

    // ── Write mtree ──────────────────────────────────────────────────────────
    var mtree_root: ?*c_libs.GFile = null;
    defer if (mtree_root) |root| c_libs.g_object_unref(root);

    if (c_libs.ostree_repo_write_mtree(repo, mtree, &mtree_root, machine.cancellable, &machine.gerror) == 0) return machine.retry(stateCommit);

    // ── Build subject ────────────────────────────────────────────────────────
    var subject_alloc = std.Io.Writer.Allocating.init(machine.allocator);
    defer subject_alloc.deinit();
    const subject_writer = &subject_alloc.writer;

    try machine.check(subject_writer.writeAll("install:"), InstallerError.AllocZFailed);
    for (machine.data.packages, 0..) |entry, index| {
        const separator = if (index == 0) " " else ", ";
        try machine.check(subject_writer.print("{s}{s} {s}", .{ separator, entry.package.meta.name, entry.package.meta.version }), InstallerError.AllocZFailed);
    }

    const subject_c = try machine.check(machine.allocator.dupeZ(u8, subject_alloc.written()), InstallerError.OutOfMemory);
    defer machine.allocator.free(subject_c);

    // ── Commit ───────────────────────────────────────────────────────────────
    if (c_libs.ostree_repo_write_commit(repo, machine.previous_commit_checksum, subject_c.ptr, body_c.ptr, null, @ptrCast(mtree_root), &machine.commit_checksum, machine.cancellable, &machine.gerror) == 0) return machine.retry(stateCommit);

    c_libs.ostree_repo_transaction_set_ref(repo, null, machine.data.branch, machine.commit_checksum);

    if (c_libs.ostree_repo_commit_transaction(repo, null, machine.cancellable, &machine.gerror) == 0) return machine.retry(stateCommit);

    machine.resetRetries();
    return stateCheckout(machine);
}

// Checks out the committed tree into a temporary staging directory, then atomically swaps it with the real target using renameat2(RENAME_EXCHANGE)
fn stateCheckout(machine: *InstallerMachine) InstallerError!void {
    machine.enter(.checkout) catch return InstallerError.OutOfMemory;

    const repo = try machine.unwrap(machine.repo, InstallerError.RepoOpenFailed);
    const estimated = estimateCheckoutSize(machine, repo, machine.commit_checksum, machine.cancellable) catch 0;

    var buf: [256]u8 = undefined;
    var stat: c_libs.struct_statvfs = undefined;
    const timestamp = std.time.milliTimestamp();

    const temp_folder_name = try machine.check(std.fmt.bufPrintZ(&buf, "{s}-remove-{d}", .{ std.mem.span(machine.data.prefix_path), timestamp }), error.AllocZFailed);

    const staging_path_c = try machine.check(std.fs.path.joinZ(machine.allocator, &.{ std.mem.span(machine.data.root_path), temp_folder_name }), InstallerError.AllocZFailed);
    machine.staging_path_c = staging_path_c;

    if (c_libs.statvfs(machine.data.root_path, &stat) == 0) {
        const available: u64 = @as(u64, @intCast(stat.f_bavail)) * @as(u64, @intCast(stat.f_bsize));
        if (estimated * 2 > available) {
            stateFailed(machine);
            return InstallerError.NotEnoughSpace;
        }
    }

    var options = std.mem.zeroes(c_libs.OstreeRepoCheckoutAtOptions);
    options.mode = c_libs.OSTREE_REPO_CHECKOUT_MODE_NONE;
    options.overwrite_mode = c_libs.OSTREE_REPO_CHECKOUT_OVERWRITE_UNION_FILES;

    if (c_libs.ostree_repo_checkout_at(repo, &options, std.c.AT.FDCWD, staging_path_c, machine.commit_checksum, machine.cancellable, &machine.gerror) == 0) {
        try machine.check(std.fs.deleteTreeAbsolute(staging_path_c), InstallerError.CheckoutFailed);

        if (machine.exhausted()) {
            stateFailed(machine);
            return InstallerError.MaxRetriesExceeded;
        }
        if (machine.gerror) |err| {
            c_libs.g_error_free(err);
            machine.gerror = null;
        }
        machine.retries += 1;

        return stateCheckout(machine);
    }

    machine.resetRetries();
    return stateAtomicSwap(machine);
}

fn stateAtomicSwap(machine: *InstallerMachine) InstallerError!void {
    machine.enter(.atomic_swap) catch return InstallerError.OutOfMemory;

    const staging_path = try machine.unwrap(machine.staging_path_c, InstallerError.CheckoutFailed);

    const root_prefix_path_c = try machine.check(std.fs.path.joinZ(machine.allocator, &.{ std.mem.span(machine.data.root_path), std.mem.span(machine.data.prefix_path) }), InstallerError.AllocZFailed);
    defer machine.allocator.free(root_prefix_path_c);

    const staging_prefix_path_c = try machine.check(std.fs.path.joinZ(machine.allocator, &.{ staging_path, std.mem.span(machine.data.prefix_path) }), InstallerError.AllocZFailed);
    defer machine.allocator.free(staging_prefix_path_c);

    const result = std.os.linux.syscall5(.renameat2, @bitCast(@as(isize, std.os.linux.AT.FDCWD)), @intFromPtr(staging_prefix_path_c.ptr), @bitCast(@as(isize, std.os.linux.AT.FDCWD)), @intFromPtr(root_prefix_path_c.ptr), 2);

    if (std.os.linux.E.init(result) != .SUCCESS) {
        try machine.check(std.fs.deleteTreeAbsolute(staging_path), InstallerError.CheckoutFailed);

        stateFailed(machine);
        return InstallerError.CheckoutFailed;
    }

    machine.resetRetries();
    return stateCleanupStaging(machine);
}

fn stateCleanupStaging(machine: *InstallerMachine) InstallerError!void {
    machine.enter(.cleanup) catch return InstallerError.OutOfMemory;

    const staging_path = try machine.unwrap(machine.staging_path_c, InstallerError.CheckoutFailed);

    try machine.check(std.fs.deleteTreeAbsolute(staging_path), InstallerError.CheckoutFailed);
    machine.allocator.free(staging_path);
    machine.staging_path_c = null;

    return stateDone(machine);
}

// Transitions the machine to its final state. Signals the caller that the package has been successfully committed to OSTree, the database has been updated, and the index has been synchronized
fn stateDone(machine: *InstallerMachine) InstallerError!void {
    machine.enter(.done) catch return InstallerError.OutOfMemory;
}

// An automaton error state, signaling that a system rollback is required
pub fn stateFailed(machine: *InstallerMachine) void {
    var abort_err: ?*c_libs.GError = null;
    defer if (abort_err) |err| c_libs.g_error_free(err);

    if (machine.staging_path_c) |staging| {
        std.fs.deleteTreeAbsolute(staging) catch {};
        machine.allocator.free(staging);
        machine.staging_path_c = null;
    }

    if (machine.repo) |repo| {
        _ = c_libs.ostree_repo_abort_transaction(repo, null, &abort_err);

        if (machine.commit_checksum != null) _ = c_libs.ostree_repo_set_ref_immediate(repo, null, machine.data.branch, null, null, null);
    }

    _ = machine.enter(.failed) catch {};
}
