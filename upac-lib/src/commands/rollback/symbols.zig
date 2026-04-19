// ── Imports ─────────────────────────────────────────────────────────────────────
const rollback = @import("rollback.zig");
const ffi = rollback.ffi;

const CRollbackRequest = ffi.CRollbackRequest;

const ErrorCode = ffi.ErrorCode;
const Operation = ffi.Operation;
const fromError = ffi.fromError;

// Reverts the system state to a specific commit hash in the OSTree repository
pub export fn upac_rollback(c_rollback_request: CRollbackRequest) callconv(.C) i32 {
    const allocator = ffi.allocator();

    rollback.rollback(c_rollback_request.repo_path.toSlice(), c_rollback_request.branch.toSlice(), c_rollback_request.commit_hash.toSlice(), c_rollback_request.root_path.toSlice(), allocator) catch |err| return @intFromEnum(fromError(err, Operation.rollback));

    return @intFromEnum(ErrorCode.ok);
}
