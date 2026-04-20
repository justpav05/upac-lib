// ── Imports ─────────────────────────────────────────────────────────────────────
const rollback = @import("rollback.zig");
const std = rollback.std;
const c_libs = rollback.file.c_libs;

const RollbackMachine = rollback.RollbackMachine;
const RollbackError = rollback.RollbackError;

const resolveStagingDir = rollback.resolveStagingDir;
const resolveStagingRootDir = rollback.resolveStagingRootDir;
const resolveStagingPrefixDir = rollback.resolveStagingPrefixDir;

pub fn stateVerifying(machine: *RollbackMachine) RollbackError!void {
    machine.enter(.verifying) catch return RollbackError.OutOfMemory;

    std.fs.accessAbsolute(machine.data.root_path, .{}) catch {
        stateFailed(machine);
        return RollbackError.RollbackFailed;
    };
    std.fs.accessAbsolute(machine.data.repo_path, .{}) catch {
        stateFailed(machine);
        return RollbackError.RepoOpenFailed;
    };

    const branch_c = std.fmt.allocPrintZ(machine.allocator, "{s}", .{machine.data.branch}) catch {
        stateFailed(machine);
        return RollbackError.AllocZFailed;
    };
    machine.branch_c = branch_c;

    machine.resetRetries();
    return stateOpenRepo(machine);
}

fn stateOpenRepo(machine: *RollbackMachine) RollbackError!void {
    machine.enter(.open_repo) catch return RollbackError.OutOfMemory;

    const repo_path_c = std.fmt.allocPrintZ(machine.allocator, "{s}", .{machine.data.repo_path}) catch {
        stateFailed(machine);
        return RollbackError.AllocZFailed;
    };
    defer machine.allocator.free(repo_path_c);

    const gfile = c_libs.g_file_new_for_path(repo_path_c.ptr);
    defer c_libs.g_object_unref(@ptrCast(gfile));

    const repo = c_libs.ostree_repo_new(gfile);

    if (c_libs.ostree_repo_open(repo, null, &machine.gerror) == 0) {
        c_libs.g_object_unref(repo);
        return machine.retry(stateOpenRepo);
    }

    machine.repo = repo;
    machine.resetRetries();
    return stateResolveCommit(machine);
}

fn stateResolveCommit(machine: *RollbackMachine) RollbackError!void {
    machine.enter(.resolve_commit) catch return RollbackError.OutOfMemory;

    const repo = machine.repo orelse return RollbackError.RepoOpenFailed;
    const commit_hash_c = std.fmt.allocPrintZ(machine.allocator, "{s}", .{machine.data.commit_hash}) catch {
        stateFailed(machine);
        return RollbackError.AllocZFailed;
    };
    defer machine.allocator.free(commit_hash_c);

    var resolved: ?[*:0]u8 = null;
    if (c_libs.ostree_repo_resolve_rev(repo, commit_hash_c.ptr, 0, &resolved, &machine.gerror) == 0) {
        stateFailed(machine);
        return RollbackError.CommitNotFound;
    }

    machine.resolved_checksum = resolved orelse {
        stateFailed(machine);
        return RollbackError.CommitNotFound;
    };

    machine.resetRetries();
    return stateCheckoutStaging(machine);
}

fn stateCheckoutStaging(machine: *RollbackMachine) RollbackError!void {
    machine.enter(.checkout_staging) catch return RollbackError.OutOfMemory;

    const repo = machine.repo orelse return RollbackError.RepoOpenFailed;
    const resolved_checksum = machine.resolved_checksum orelse return RollbackError.CommitNotFound;

    const staging_path = resolveStagingPrefixDir(machine.data.root_path, machine.data.prefix, machine.allocator) catch {
        stateFailed(machine);
        return RollbackError.AllocZFailed;
    };
    machine.staging_path = staging_path;

    var options = std.mem.zeroes(c_libs.OstreeRepoCheckoutAtOptions);
    options.mode = c_libs.OSTREE_REPO_CHECKOUT_MODE_NONE;
    options.overwrite_mode = c_libs.OSTREE_REPO_CHECKOUT_OVERWRITE_NONE;

    if (c_libs.ostree_repo_checkout_at(repo, &options, std.c.AT.FDCWD, staging_path.ptr, resolved_checksum, null, &machine.gerror) == 0) {
        std.fs.deleteTreeAbsolute(staging_path) catch {};
        machine.allocator.free(staging_path);
        machine.staging_path = null;
        return machine.retry(stateCheckoutStaging);
    }

    machine.resetRetries();
    return stateAtomicSwap(machine);
}

fn stateAtomicSwap(machine: *RollbackMachine) RollbackError!void {
    machine.enter(.atomic_swap) catch return RollbackError.OutOfMemory;

    const staging_path = machine.staging_path orelse {
        stateFailed(machine);
        return RollbackError.StagingFailed;
    };

    const root_usr = resolveStagingRootDir(machine.data.root_path, machine.data.prefix, machine.allocator) catch {
        stateFailed(machine);
        return RollbackError.AllocZFailed;
    };
    defer machine.allocator.free(root_usr);

    const staging_usr = resolveStagingPrefixDir(staging_path, machine.data.prefix, machine.allocator) catch {
        stateFailed(machine);
        return RollbackError.AllocZFailed;
    };
    defer machine.allocator.free(staging_usr);

    const result = std.os.linux.syscall5(.renameat2, @bitCast(@as(isize, std.os.linux.AT.FDCWD)), @intFromPtr(staging_usr.ptr), @bitCast(@as(isize, std.os.linux.AT.FDCWD)), @intFromPtr(root_usr.ptr), 2);

    if (std.os.linux.E.init(result) != .SUCCESS) {
        std.fs.deleteTreeAbsolute(staging_path) catch {
            stateFailed(machine);
            return RollbackError.CleanupFailed;
        };
        stateFailed(machine);
        return RollbackError.SwapFailed;
    }

    machine.resetRetries();
    return stateCleanupStaging(machine);
}

fn stateCleanupStaging(machine: *RollbackMachine) RollbackError!void {
    machine.enter(.cleanup_staging) catch return RollbackError.OutOfMemory;

    if (machine.staging_path) |staging_path| {
        std.fs.deleteTreeAbsolute(staging_path) catch {
            stateFailed(machine);
            return RollbackError.CleanupFailed;
        };
        machine.allocator.free(staging_path);
        machine.staging_path = null;
    }

    machine.resetRetries();
    return stateUpdateRef(machine);
}

fn stateUpdateRef(machine: *RollbackMachine) RollbackError!void {
    machine.enter(.update_ref) catch return RollbackError.OutOfMemory;

    const repo = machine.repo orelse return RollbackError.RepoOpenFailed;
    const branch_c = machine.branch_c orelse return RollbackError.AllocZFailed;
    const resolved_checksum = machine.resolved_checksum orelse return RollbackError.CommitNotFound;

    if (c_libs.ostree_repo_prepare_transaction(repo, null, null, &machine.gerror) == 0)
        return machine.retry(stateUpdateRef);

    c_libs.ostree_repo_transaction_set_ref(repo, null, branch_c.ptr, resolved_checksum);

    if (c_libs.ostree_repo_commit_transaction(repo, null, null, &machine.gerror) == 0) {
        _ = c_libs.ostree_repo_abort_transaction(repo, null, null);
        return machine.retry(stateUpdateRef);
    }

    machine.resetRetries();
    return stateDone(machine);
}

fn stateDone(machine: *RollbackMachine) RollbackError!void {
    machine.enter(.done) catch return RollbackError.OutOfMemory;
}

pub fn stateFailed(machine: *RollbackMachine) void {
    if (machine.staging_path) |staging| {
        std.fs.deleteTreeAbsolute(staging) catch {};
        machine.allocator.free(staging);
        machine.staging_path = null;
    }
    _ = machine.enter(.failed) catch {};
}
