// ── Imports ─────────────────────────────────────────────────────────────────────
const rollback = @import("rollback.zig");
const std = rollback.std;
const c_libs = rollback.file.c_libs;

const RollbackMachine = rollback.RollbackMachine;
const RollbackError = rollback.RollbackError;

const utils = @import("utils.zig");
const resolveStagingDir = utils.resolveStagingDir;
const resolveRootDir = utils.resolveRootDir;

pub fn stateVerifying(machine: *RollbackMachine) RollbackError!void {
    machine.enter(.verifying) catch return error.OutOfMemory;

    try machine.check(std.fs.accessAbsoluteZ(machine.data.root_path, .{}), RollbackError.PathNotFound);
    try machine.check(std.fs.accessAbsoluteZ(machine.data.repo_path, .{}), RollbackError.PathNotFound);

    const prefix_directory = try machine.check(std.fs.path.join(machine.allocator, &.{ std.mem.span(machine.data.root_path), std.mem.span(machine.data.prefix_path) }), RollbackError.AllocZFailed);
    defer machine.allocator.free(prefix_directory);

    try machine.check(std.fs.accessAbsolute(prefix_directory, .{}), RollbackError.PathNotFound);

    machine.resetRetries();
    return stateOpenRepo(machine);
}

fn stateOpenRepo(machine: *RollbackMachine) RollbackError!void {
    machine.enter(.open_repo) catch return error.OutOfMemory;

    const gfile = c_libs.g_file_new_for_path(machine.data.repo_path);
    defer c_libs.g_object_unref(@ptrCast(gfile));

    const repo = c_libs.ostree_repo_new(gfile);
    if (c_libs.ostree_repo_open(repo, machine.cancellable, &machine.gerror) == 0) {
        c_libs.g_object_unref(repo);
        return machine.retry(stateOpenRepo);
    }

    machine.repo = repo;
    machine.resetRetries();
    return stateResolveCommit(machine);
}

fn stateResolveCommit(machine: *RollbackMachine) RollbackError!void {
    machine.enter(.resolve_commit) catch return error.OutOfMemory;

    const repo = try machine.unwrap(machine.repo, error.RepoOpenFailed);

    var resolved: ?[*:0]u8 = null;
    try machine.gcheck(c_libs.ostree_repo_resolve_rev(repo, machine.data.commit_hash, 0, &resolved, &machine.gerror), error.CommitNotFound);

    machine.resolved_checksum = try machine.unwrap(resolved, error.CommitNotFound);

    machine.resetRetries();
    return stateCheckoutStaging(machine);
}

fn stateCheckoutStaging(machine: *RollbackMachine) RollbackError!void {
    machine.enter(.checkout_staging) catch return error.OutOfMemory;

    const repo = try machine.unwrap(machine.repo, error.RepoOpenFailed);
    const resolved_checksum = try machine.unwrap(machine.resolved_checksum, error.CommitNotFound);

    machine.staging_path_c = try resolveStagingDir(std.mem.span(machine.data.root_path), std.mem.span(machine.data.prefix_path), machine.allocator);
    const staging_path_c = try machine.unwrap(machine.staging_path_c, error.StagingFailed);

    try machine.check(std.fs.makeDirAbsolute(staging_path_c), RollbackError.StagingFailed);

    var options = std.mem.zeroes(c_libs.OstreeRepoCheckoutAtOptions);
    options.mode = c_libs.OSTREE_REPO_CHECKOUT_MODE_NONE;
    options.overwrite_mode = c_libs.OSTREE_REPO_CHECKOUT_OVERWRITE_ADD_FILES;
    options.no_copy_fallback = 0;

    if (c_libs.ostree_repo_checkout_at(repo, &options, std.c.AT.FDCWD, staging_path_c, resolved_checksum, machine.cancellable, &machine.gerror) == 0) {
        try machine.check(std.fs.deleteTreeAbsolute(staging_path_c), RollbackError.RollbackFailed);

        machine.allocator.free(staging_path_c);
        machine.staging_path_c = null;

        return machine.retry(stateVerifying);
    }

    machine.resetRetries();
    return stateAtomicSwap(machine);
}

fn stateAtomicSwap(machine: *RollbackMachine) RollbackError!void {
    machine.enter(.atomic_swap) catch return error.OutOfMemory;

    const staging_path_c = try machine.unwrap(machine.staging_path_c, error.StagingFailed);

    const root_prefix_path = try resolveRootDir(std.mem.span(machine.data.root_path), std.mem.span(machine.data.prefix_path), machine.allocator);
    defer machine.allocator.free(root_prefix_path);

    const staging_prefix_path = try resolveRootDir(staging_path_c, std.mem.span(machine.data.prefix_path), machine.allocator);
    defer machine.allocator.free(staging_prefix_path);

    const result = std.os.linux.syscall5(.renameat2, @bitCast(@as(isize, std.os.linux.AT.FDCWD)), @intFromPtr(staging_prefix_path.ptr), @bitCast(@as(isize, std.os.linux.AT.FDCWD)), @intFromPtr(root_prefix_path.ptr), 2);

    if (std.os.linux.E.init(result) != .SUCCESS) {
        stateFailed(machine);
        return error.SwapFailed;
    }

    machine.resetRetries();
    return stateCleanupStaging(machine);
}

fn stateCleanupStaging(machine: *RollbackMachine) RollbackError!void {
    machine.enter(.cleanup_staging) catch return error.OutOfMemory;

    const staging_path_c = try machine.unwrap(machine.staging_path_c, error.StagingFailed);

    try machine.check(std.fs.deleteTreeAbsolute(staging_path_c), RollbackError.CleanupFailed);

    machine.allocator.free(staging_path_c);
    machine.staging_path_c = null;

    machine.resetRetries();
    return stateUpdateRef(machine);
}

fn stateUpdateRef(machine: *RollbackMachine) RollbackError!void {
    machine.enter(.update_ref) catch return error.OutOfMemory;

    const repo = try machine.unwrap(machine.repo, error.RepoOpenFailed);
    const resolved_checksum = try machine.unwrap(machine.resolved_checksum, error.CommitNotFound);

    if (c_libs.ostree_repo_prepare_transaction(repo, null, machine.cancellable, &machine.gerror) == 0) return machine.retry(stateUpdateRef);

    c_libs.ostree_repo_transaction_set_ref(repo, null, machine.data.branch, resolved_checksum);

    if (c_libs.ostree_repo_commit_transaction(repo, null, machine.cancellable, &machine.gerror) == 0) {
        _ = c_libs.ostree_repo_abort_transaction(repo, machine.cancellable, null);
        return machine.retry(stateUpdateRef);
    }

    machine.resetRetries();
    return stateDone(machine);
}

fn stateDone(machine: *RollbackMachine) RollbackError!void {
    machine.enter(.done) catch return error.OutOfMemory;
}

pub fn stateFailed(machine: *RollbackMachine) void {
    if (machine.staging_path_c) |staging_path| {
        std.fs.deleteTreeAbsolute(staging_path) catch {};
        machine.allocator.free(staging_path);
        machine.staging_path_c = null;
    }
    _ = machine.enter(.failed) catch {};
}
