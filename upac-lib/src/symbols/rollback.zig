// ── Imports ─────────────────────────────────────────────────────────────────────
const rollback_module = @import("upac-rollback");
const std = rollback_module.std;

const CRollbackRequest = rollback_module.ffi.CMutatedRequest;

const ErrorCode = rollback_module.ffi.ErrorCode;
const Operation = rollback_module.ffi.Operation;
const fromError = rollback_module.ffi.fromError;

// Reverts the system state to a specific commit hash in the OSTree repository
pub fn rollback(rollback_request_c: CRollbackRequest) callconv(.c) i32 {
    rollback_request_c.validate() catch |err| return @intFromEnum(fromError(err, Operation.rollback));

    if (rollback_request_c.commit_hash.len == 0) return @intFromEnum(fromError(error.InvalidEntry, Operation.rollback));
    rollback_request_c.commit_hash.validate() catch return @intFromEnum(fromError(error.InvalidEntry, Operation.rollback));

    const rollback_data = rollback_module.RollbackData{
        .root_path = rollback_request_c.root_path.asZ(),
        .repo_path = rollback_request_c.repo_path.asZ(),
        .prefix_path = rollback_request_c.prefix_directory.asZ(),

        .branch = rollback_request_c.branch.asZ(),
        .commit_hash = rollback_request_c.commit_hash.asZ(),
    };

    rollback_module.RollbackMachine.run(rollback_data, rollback_module.ffi.allocator()) catch |err| return @intFromEnum(fromError(err, Operation.rollback));

    return @intFromEnum(ErrorCode.ok);
}
