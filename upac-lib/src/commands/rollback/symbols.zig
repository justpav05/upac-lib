// ── Imports ─────────────────────────────────────────────────────────────────────
const rollback = @import("rollback.zig");
const ffi = rollback.ffi;

const CRollbackRequest = ffi.CRollbackRequest;

const ErrorCode = ffi.ErrorCode;
const Operation = ffi.Operation;
const fromError = ffi.fromError;

// Reverts the system state to a specific commit hash in the OSTree repository
pub export fn upac_rollback(rollback_request_c: CRollbackRequest) callconv(.C) i32 {
    rollback_request_c.validate() catch |err| return @intFromEnum(fromError(err, Operation.rollback));

    const rollback_data = rollback.RollbackData{
        .root_path = rollback_request_c.root_path.toSlice(),
        .repo_path = rollback_request_c.repo_path.toSlice(),

        .branch = rollback_request_c.branch.toSlice(),
        .prefix = rollback_request_c.prefix.toSlice(),

        .commit_hash = rollback_request_c.commit_hash.toSlice(),
    };

    rollback.RollbackMachine.run(rollback_data, ffi.allocator()) catch |err| return @intFromEnum(fromError(err, Operation.rollback));

    return @intFromEnum(ErrorCode.ok);
}
