// ── Imports ─────────────────────────────────────────────────────────────────────
const installer = @import("installer.zig");
const std = installer.std;
const c_libs = installer.c_libs;
const data = installer.data;

const InstallerMachine = installer.InstallerMachine;
const InstallerError = installer.InstallerError;

const find = data.find;
const append = data.append;
const remove = data.remove;

const utils = @import("utils.zig");
const dirSize = utils.dirSize;
const collectFileChecksums = utils.collectFileChecksums;
const estimateCheckoutSize = utils.estimateCheckoutSize;

const loadCommitBody = utils.loadCommitBody;

// ── InstallerFSM states ─────────────────────────────────────────────────────────────────
// It verifies the physical existence of the temporary package folder and the repository path. If the paths do not exist, the installation is immediately aborted
pub fn stateVerifying(machine: *InstallerMachine) InstallerError!void {
    try machine.check(machine.enter(.verifying), InstallerError.OutOfMemory);

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
    try machine.check(machine.enter(.check_space), InstallerError.OutOfMemory);

    var new_packages_size: u64 = 0;
    for (machine.data.packages) |entry| new_packages_size += try machine.check(dirSize(machine.allocator, entry.temp_path), InstallerError.CheckSpaceFailed);

    const prefix_path = try machine.prefixPathZ();
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
    try machine.check(machine.enter(.open_repo), InstallerError.OutOfMemory);

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
    try machine.check(machine.enter(.check_installed), InstallerError.OutOfMemory);

    const body = try loadCommitBody(machine, machine.previous_commit_checksum);
    defer machine.allocator.free(body);

    const current_name = machine.data.packages[machine.current_package_index].package.meta.name;

    if (try machine.check(find(body, current_name, machine.allocator), InstallerError.AllocZFailed) != null) {
        stateFailed(machine);
        return InstallerError.AlreadyInstalled;
    }

    machine.resetRetries();
    return stateWriteDatabase(machine);
}

// Once the files have been processed, this function saves the data to the local upac database (.meta and .files) so that the system knows the package is installed
fn stateWriteDatabase(machine: *InstallerMachine) InstallerError!void {
    try machine.check(machine.enter(.write_database), InstallerError.OutOfMemory);

    const current_install_entry = machine.data.packages[machine.current_package_index];

    const relative_database_path = if (std.mem.startsWith(u8, std.mem.span(machine.data.database_path), std.mem.span(machine.data.root_path)))
        std.mem.span(machine.data.database_path)[std.mem.span(machine.data.root_path).len..]
    else
        std.mem.span(machine.data.database_path);

    const staged_database_dir_path = try machine.check(std.fs.path.join(machine.allocator, &.{ current_install_entry.temp_path, relative_database_path }), InstallerError.AllocZFailed);
    defer machine.allocator.free(staged_database_dir_path);

    try machine.check(std.fs.cwd().makePath(staged_database_dir_path), InstallerError.AllocZFailed);

    var file_map = data.FileMap.init(machine.allocator);
    defer data.freeFileMap(&file_map, machine.allocator);

    try machine.check(collectFileChecksums(machine, &file_map), InstallerError.CollectFileChecksumsFailed);

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

    var body = try loadCommitBody(machine, machine.previous_commit_checksum);
    for (machine.data.packages) |entry| {
        const new_body = append(body, entry.package.meta.name, entry.checksum, machine.allocator) catch return InstallerError.AllocZFailed;
        machine.allocator.free(body);
        body = new_body;
    }
    defer machine.allocator.free(body);

    const body_c = try machine.check(machine.allocator.dupeZ(u8, body), InstallerError.AllocZFailed);
    defer machine.allocator.free(body_c);

    var mtree_root: ?*c_libs.GFile = null;
    defer if (mtree_root) |root| c_libs.g_object_unref(root);

    if (c_libs.ostree_repo_write_mtree(repo, mtree, &mtree_root, machine.cancellable, &machine.gerror) == 0)
        return machine.retry(stateCommit);

    var subject_buf = std.Io.Writer.Allocating.init(machine.allocator);
    defer subject_buf.deinit();

    try machine.check(subject_buf.writer.writeAll("install:"), InstallerError.AllocZFailed);
    for (machine.data.packages, 0..) |entry, i| {
        try machine.check(subject_buf.writer.print("{s}{s} {s}", .{ if (i == 0) " " else ", ", entry.package.meta.name, entry.package.meta.version }), InstallerError.AllocZFailed);
    }

    const subject_c = try machine.check(machine.allocator.dupeZ(u8, subject_buf.written()), InstallerError.AllocZFailed);
    defer machine.allocator.free(subject_c);

    if (c_libs.ostree_repo_write_commit(repo, machine.previous_commit_checksum, subject_c.ptr, body_c.ptr, null, @ptrCast(mtree_root), &machine.commit_checksum, machine.cancellable, &machine.gerror) == 0) return machine.retry(stateCommit);

    c_libs.ostree_repo_transaction_set_ref(repo, null, machine.data.branch, machine.commit_checksum);

    if (c_libs.ostree_repo_commit_transaction(repo, null, machine.cancellable, &machine.gerror) == 0) return machine.retry(stateCommit);

    machine.resetRetries();
    return stateCheckout(machine);
}

// Checks out the committed tree into a temporary staging directory, then atomically swaps it with the real target using renameat2(RENAME_EXCHANGE)
fn stateCheckout(machine: *InstallerMachine) InstallerError!void {
    try machine.check(machine.enter(.checkout), InstallerError.OutOfMemory);

    const repo = try machine.unwrap(machine.repo, InstallerError.RepoOpenFailed);
    const estimated = estimateCheckoutSize(machine) catch 0;

    var buf: [256]u8 = undefined;
    const timestamp = std.time.milliTimestamp();
    var stat: c_libs.struct_statvfs = undefined;
    if (c_libs.statvfs(machine.data.root_path, &stat) == 0 and estimated * 2 > @as(u64, stat.f_bavail) * @as(u64, stat.f_bsize)) {
        stateFailed(machine);
        return InstallerError.NotEnoughSpace;
    }

    const temp_folder_name = try machine.check(std.fmt.bufPrintZ(&buf, "{s}-install-{d}", .{ std.mem.span(machine.data.prefix_path), timestamp }), error.AllocZFailed);

    const staging_path_c = try machine.check(std.fs.path.joinZ(machine.allocator, &.{ std.mem.span(machine.data.root_path), temp_folder_name }), InstallerError.AllocZFailed);
    machine.staging_path_c = staging_path_c;

    std.debug.print("{any}", .{machine.commit_checksum == null});

    var options = std.mem.zeroes(c_libs.OstreeRepoCheckoutAtOptions);
    options.mode = c_libs.OSTREE_REPO_CHECKOUT_MODE_NONE;
    options.overwrite_mode = c_libs.OSTREE_REPO_CHECKOUT_OVERWRITE_UNION_FILES;


    if (machine.commit_checksum == null) {
        stateFailed(machine);
        return InstallerError.CheckoutFailed;
    } else if (c_libs.ostree_repo_checkout_at(repo, &options, std.c.AT.FDCWD, staging_path_c, machine.commit_checksum, machine.cancellable, &machine.gerror) == 0) {
        try machine.check(std.fs.deleteTreeAbsolute(staging_path_c), InstallerError.CheckoutFailed);
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
    try machine.check(machine.enter(.atomic_swap), InstallerError.OutOfMemory);

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
    try machine.check(machine.enter(.cleanup), InstallerError.OutOfMemory);

    const staging_path = try machine.unwrap(machine.staging_path_c, InstallerError.CheckoutFailed);

    try machine.check(std.fs.deleteTreeAbsolute(staging_path), InstallerError.CheckoutFailed);
    machine.allocator.free(staging_path);
    machine.staging_path_c = null;

    return stateDone(machine);
}

// Transitions the machine to its final state. Signals the caller that the package has been successfully committed to OSTree, the database has been updated, and the index has been synchronized
fn stateDone(machine: *InstallerMachine) InstallerError!void {
    try machine.check(machine.enter(.done), InstallerError.OutOfMemory);
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
