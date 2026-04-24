// ── Imports ─────────────────────────────────────────────────────────────────────
const std = @import("std");

const data = @import("upac-data");

const file = @import("upac-file");
const c_libs = file.c_libs;

const uninstaller = @import("uninstaller.zig");
const CSlice = uninstaller.CSlice;

const UninstallerMachine = uninstaller.UninstallerMachine;
const UninstallerError = uninstaller.UninstallerError;

const utils = @import("utils.zig");

const resolveMtree = utils.resolveMtree;

const removeDbFile = utils.removeDbFile;
const removeFromMtree = utils.removeFromMtree;

const buildCommitBody = utils.buildCommitBody;
const buildCommitSubject = utils.buildCommitSubject;

// ── States ─────────────────────────────────────────────────────────────────────
// The status of the path validation check
pub fn stateVerifying(machine: *UninstallerMachine) UninstallerError!void {
    try machine.enter(.verifying);

    try machine.check(std.fs.accessAbsoluteZ(machine.data.root_path, .{}), UninstallerError.PathNotFound);
    try machine.check(std.fs.accessAbsoluteZ(machine.data.repo_path, .{}), UninstallerError.PathNotFound);

    const root_prefix_path_c = try machine.check(std.fs.path.joinZ(machine.allocator, &.{ std.mem.span(machine.data.root_path), std.mem.span(machine.data.prefix_path) }), error.AllocZFailed);
    defer machine.allocator.free(root_prefix_path_c);

    try machine.check(std.fs.accessAbsoluteZ(root_prefix_path_c, .{}), UninstallerError.PathNotFound);

    machine.resetRetries();
    return stateOpenRepo(machine);
}

// The state of opening the repository and writing its data to the machine
fn stateOpenRepo(machine: *UninstallerMachine) UninstallerError!void {
    try machine.enter(.open_repo);

    if (machine.mtree) |mtree| c_libs.g_object_unref(mtree);

    const gfile = c_libs.g_file_new_for_path(machine.data.repo_path);
    defer c_libs.g_object_unref(@ptrCast(gfile));

    machine.repo = c_libs.ostree_repo_new(gfile);

    const repo = try machine.unwrap(machine.repo, error.RepoOpenFailed);

    if (c_libs.ostree_repo_open(repo, machine.cancellable, &machine.gerror) == 0) {
        c_libs.g_object_unref(machine.repo);
        return machine.retry(stateOpenRepo);
    }

    try machine.gcheck(c_libs.ostree_repo_prepare_transaction(repo, null, machine.cancellable, &machine.gerror), error.RepoTransactionFailed);

    machine.mtree = resolveMtree(machine, repo);

    machine.resetRetries();
    return stateCheckInstalled(machine);
}

// Installation verification status, designed to prevent the removal of non-existent items
fn stateCheckInstalled(machine: *UninstallerMachine) UninstallerError!void {
    try machine.enter(.check_installed);

    var body_len: usize = 0;
    var body_variant: ?*c_libs.GVariant = null;
    defer if (body_variant) |variant| c_libs.g_variant_unref(variant);

    const repo = try machine.unwrap(machine.repo, error.RepoOpenFailed);
    const previos_commit_checksum = try machine.unwrap(machine.previous_commit_checksum, error.PackageNotFound);

    var commit_variant: ?*c_libs.GVariant = null;
    defer if (commit_variant) |variant| c_libs.g_variant_unref(variant);

    try machine.gcheck(c_libs.ostree_repo_load_variant(repo, c_libs.OSTREE_OBJECT_TYPE_COMMIT, previos_commit_checksum, &commit_variant, &machine.gerror), error.PackageNotFound);

    body_variant = c_libs.g_variant_get_child_value(commit_variant, 4);
    const body_ptr = c_libs.g_variant_get_string(body_variant, &body_len);
    const body = body_ptr[0..body_len];

    var split_lines_iter = std.mem.splitScalar(u8, body, '\n');
    while (split_lines_iter.next()) |line| {
        const trimmed_line = std.mem.trim(u8, line, " \t\r");
        if (trimmed_line.len == 0) continue;

        const separator_index = std.mem.indexOfScalar(u8, trimmed_line, ' ') orelse continue;
        const pkg_name = trimmed_line[0..separator_index];
        const pkg_checksum = std.mem.trim(u8, trimmed_line[separator_index + 1 ..], " \t");

        if (std.ascii.eqlIgnoreCase(pkg_name, machine.data.package_names[machine.current_package_index])) {
            machine.package_checksum = try machine.allocator.dupe(u8, pkg_checksum);
            machine.resetRetries();
            return stateLoadFiles(machine);
        }
    }

    stateFailed(machine);
    return error.PackageNotFound;
}

// State for loading the list of paths created during installation, in order to precisely identify which OSTree tree nodes need to be removed
fn stateLoadFiles(machine: *UninstallerMachine) UninstallerError!void {
    try machine.enter(.load_files);

    const package_checksum = try machine.unwrap(machine.package_checksum, error.PackageNotFound);

    machine.package_file_map = try machine.check(data.readFiles(std.mem.span(machine.data.database_path), package_checksum, machine.allocator), UninstallerError.FileMapCorrupted);

    machine.resetRetries();
    return stateRemoveFiles(machine);
}

// State of file removal from mtree
fn stateRemoveFiles(machine: *UninstallerMachine) !void {
    try machine.enter(.remove_files);

    const repo = try machine.unwrap(machine.repo, error.RepoOpenFailed);
    const mtree = try machine.unwrap(machine.mtree, error.PackageNotFound);
    const file_map = try machine.unwrap(machine.package_file_map, error.PackageNotFound);

    var iter = file_map.iterator();
    while (iter.next()) |entry| removeFromMtree(repo, mtree, entry.key_ptr.*, machine.allocator) catch return machine.retry(stateRemoveFiles);

    machine.resetRetries();
    return stateRemoveDbFiles(machine);
}

// The state of removal from the global index, as well as of files belonging to the package in the database
fn stateRemoveDbFiles(machine: *UninstallerMachine) UninstallerError!void {
    try machine.enter(.remove_db_files);

    const repo = try machine.unwrap(machine.repo, error.RepoOpenFailed);
    const mtree = try machine.unwrap(machine.mtree, error.PackageNotFound);
    const pkg_checksum = try machine.unwrap(machine.package_checksum, error.PackageNotFound);

    const relative_database_path = if (std.mem.startsWith(u8, std.mem.span(machine.data.database_path), std.mem.span(machine.data.root_path)))
        machine.data.database_path[std.mem.span(machine.data.root_path).len..]
    else
        machine.data.database_path;

    try removeDbFile(machine, repo, mtree, pkg_checksum, std.mem.span(relative_database_path), ".meta");
    try removeDbFile(machine, repo, mtree, pkg_checksum, std.mem.span(relative_database_path), ".files");

    if (machine.package_file_map) |*file_map| {
        data.freeFileMap(file_map, machine.allocator);
        machine.package_file_map = null;
    }
    if (machine.package_checksum) |checksum| {
        machine.allocator.free(checksum);
        machine.package_checksum = null;
    }

    machine.current_package_index += 1;
    if (machine.current_package_index < machine.data.package_names.len) {
        machine.resetRetries();
        return stateCheckInstalled(machine);
    }

    machine.resetRetries();
    return stateCommit(machine);
}

// Creates a new commit in OSTree representing the system state without the files of this package
fn stateCommit(machine: *UninstallerMachine) UninstallerError!void {
    try machine.enter(.commit);

    const repo = try machine.unwrap(machine.repo, error.RepoOpenFailed);
    const mtree = try machine.unwrap(machine.mtree, error.PackageNotFound);
    const previos_commit_checksum = try machine.unwrap(machine.previous_commit_checksum, error.PackageNotFound);

    var body_buf = std.ArrayList(u8).init(machine.allocator);
    defer body_buf.deinit();

    try buildCommitBody(machine, repo, previos_commit_checksum, body_buf.writer());

    const body_c = machine.allocator.dupeZ(u8, body_buf.items) catch return error.AllocZFailed;
    defer machine.allocator.free(body_c);

    var out_g_file: ?*c_libs.GFile = null;
    defer if (out_g_file) |g_file| c_libs.g_object_unref(@ptrCast(g_file));
    if (c_libs.ostree_repo_write_mtree(repo, mtree, &out_g_file, machine.cancellable, &machine.gerror) == 0) return machine.retry(stateCommit);

    const subject_c = try buildCommitSubject(machine);
    defer machine.allocator.free(subject_c);

    var commit_checksum: ?[*:0]u8 = null;
    if (c_libs.ostree_repo_write_commit(repo, previos_commit_checksum, subject_c.ptr, body_c.ptr, null, @as(?*c_libs.OstreeRepoFile, @ptrCast(out_g_file)), &commit_checksum, machine.cancellable, &machine.gerror) == 0) return machine.retry(stateCommit);

    c_libs.ostree_repo_transaction_set_ref(repo, null, machine.data.branch, commit_checksum);

    if (c_libs.ostree_repo_commit_transaction(repo, null, machine.cancellable, &machine.gerror) == 0) return machine.retry(stateCommit);

    machine.commit_checksum = commit_checksum;
    machine.resetRetries();
    return stateCheckoutStaging(machine);
}

fn stateCheckoutStaging(machine: *UninstallerMachine) UninstallerError!void {
    try machine.enter(.checkout_staging);

    const repo = try machine.unwrap(machine.repo, error.AllocZFailed);

    var buf: [256]u8 = undefined;
    const timestamp = std.time.milliTimestamp();

    const temp_folder_name = try machine.check(std.fmt.bufPrintZ(&buf, "{s}-remove-{d}", .{ machine.data.prefix_path, timestamp }), UninstallerError.AllocZFailed);
    machine.staging_path_c = try machine.check(std.fs.path.joinZ(machine.allocator, &.{ std.mem.span(machine.data.root_path), temp_folder_name }), UninstallerError.AllocZFailed);

    var options = std.mem.zeroes(c_libs.OstreeRepoCheckoutAtOptions);
    options.mode = c_libs.OSTREE_REPO_CHECKOUT_MODE_NONE;
    options.overwrite_mode = c_libs.OSTREE_REPO_CHECKOUT_OVERWRITE_NONE;

    if (c_libs.ostree_repo_checkout_at(repo, &options, std.c.AT.FDCWD, machine.staging_path_c.?, machine.commit_checksum.?, machine.cancellable, &machine.gerror) == 0) {
        const staging_path_c = try machine.unwrap(machine.staging_path_c, UninstallerError.CheckoutFailed);
        try machine.check(std.fs.deleteTreeAbsolute(staging_path_c), error.MaxRetriesExceeded);

        machine.staging_path_c = null;

        stateFailed(machine);
        return error.CheckoutFailed;
    }

    return stateAtomicSwap(machine);
}

fn stateAtomicSwap(machine: *UninstallerMachine) UninstallerError!void {
    try machine.enter(.atomic_swap);

    const staging_path_c = try machine.unwrap(machine.staging_path_c, error.AllocZFailed);

    const root_prefix_path_c = try machine.check(std.fs.path.joinZ(machine.allocator, &.{ std.mem.span(machine.data.root_path), std.mem.span(machine.data.prefix_path) }), UninstallerError.AllocZFailed);
    defer machine.allocator.free(root_prefix_path_c);

    const staging_prefix_path_c = try machine.check(std.fs.path.joinZ(machine.allocator, &.{ staging_path_c, std.mem.span(machine.data.prefix_path) }), UninstallerError.AllocZFailed);
    defer machine.allocator.free(staging_prefix_path_c);

    const result = std.os.linux.syscall5(.renameat2, @bitCast(@as(isize, std.os.linux.AT.FDCWD)), @intFromPtr(staging_prefix_path_c.ptr), @bitCast(@as(isize, std.os.linux.AT.FDCWD)), @intFromPtr(root_prefix_path_c.ptr), 2);

    if (std.os.linux.E.init(result) != .SUCCESS) try machine.check(std.fs.deleteTreeAbsolute(staging_path_c), UninstallerError.CheckoutFailed);

    return stateCleanupStaging(machine);
}

fn stateCleanupStaging(machine: *UninstallerMachine) UninstallerError!void {
    try machine.enter(.cleanup_staging);

    const staging_path_c = try machine.unwrap(machine.staging_path_c, UninstallerError.AllocZFailed);
    try machine.check(std.fs.deleteTreeAbsolute(staging_path_c), UninstallerError.CheckoutFailed);

    return stateDone(machine);
}

// State of successful completion of the package removal process and deployment of the new commit
fn stateDone(machine: *UninstallerMachine) UninstallerError!void {
    try machine.enter(.done);
}

// A state of unsuccessful package removal, signaling the system that a rollback is required to revert the changes
pub fn stateFailed(machine: *UninstallerMachine) void {
    if (machine.staging_path_c) |staging_path| {
        std.fs.deleteTreeAbsolute(staging_path) catch {};
        machine.allocator.free(staging_path);
        machine.staging_path_c = null;
    }

    if (machine.repo) |repo| {
        _ = c_libs.ostree_repo_abort_transaction(repo, null, &machine.gerror);

        if (machine.commit_checksum != null) {
            _ = c_libs.ostree_repo_set_ref_immediate(repo, null, machine.data.branch, machine.previous_commit_checksum, null, null);
        }
    }

    _ = machine.enter(.failed) catch {};
}
