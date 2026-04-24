// ── Imports ─────────────────────────────────────────────────────────────────────
const rollback = @import("rollback.zig");
const std = rollback.std;

const CRollbackRequest = rollback.ffi.CRollbackRequest;

const ErrorCode = rollback.ffi.ErrorCode;
const Operation = rollback.ffi.Operation;
const fromError = rollback.ffi.fromError;

// Reverts the system state to a specific commit hash in the OSTree repository
pub export fn upac_rollback(rollback_request_c: CRollbackRequest) callconv(.C) i32 {
    rollback_request_c.validate() catch |err| return @intFromEnum(fromError(err, Operation.rollback));

    var arena_allocator = std.heap.ArenaAllocator.init(rollback.ffi.allocator());
    defer arena_allocator.deinit();

    const rollback_data = rollback.RollbackData{
        .root_path = arena_allocator.allocator().dupeZ(u8, rollback_request_c.root_path.toSlice()) catch return @intFromEnum(fromError(error.AllocZFailed, Operation.uninstall)),
        .repo_path = arena_allocator.allocator().dupeZ(u8, rollback_request_c.repo_path.toSlice()) catch return @intFromEnum(fromError(error.AllocZFailed, Operation.uninstall)),
        .prefix_path = arena_allocator.allocator().dupeZ(u8, rollback_request_c.prefix.toSlice()) catch return @intFromEnum(fromError(error.AllocZFailed, Operation.uninstall)),

        .branch = arena_allocator.allocator().dupeZ(u8, rollback_request_c.branch.toSlice()) catch return @intFromEnum(fromError(error.AllocZFailed, Operation.uninstall)),
        .commit_hash = arena_allocator.allocator().dupeZ(u8, rollback_request_c.commit_hash.toSlice()) catch return @intFromEnum(fromError(error.AllocZFailed, Operation.uninstall)),
    };

    rollback.RollbackMachine.run(rollback_data, rollback.ffi.allocator()) catch |err| return @intFromEnum(fromError(err, Operation.rollback));

    return @intFromEnum(ErrorCode.ok);
}
