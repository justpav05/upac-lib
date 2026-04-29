// ── Imports ─────────────────────────────────────────────────────────────────────
const init_module = @import("upac-init");
const std = init_module.std;

const CSlice = init_module.ffi.CSlice;
const CRepoMode = init_module.ffi.CRepoMode;
const CInitRequest = init_module.ffi.CUnmutatedRequest;

const ErrorCode = init_module.ffi.ErrorCode;
const Operation = init_module.ffi.Operation;
const fromError = init_module.ffi.fromError;

// Initializes system paths and the OSTree repository in the selected mode (archive, bare, etc.)
pub fn init(init_request_c: CInitRequest) callconv(.c) i32 {
    init_request_c.validate() catch |err| return @intFromEnum(fromError(err, Operation.init));

    const required = [_]CSlice{ init_request_c.repo_path, init_request_c.root_path, init_request_c.prefix, init_request_c.branch };
    for (required) |field| {
        if (field.len == 0 or field.ptr[field.len] != 0) return @intFromEnum(fromError(error.InvalidEntry, Operation.init));
    }

    init_module.initSystem(init_request_c.repo_path.asZ(), init_request_c.root_path.asZ(), init_request_c.repo_mode, init_request_c.branch.asZ(), init_request_c.prefix.toSlice(), &.{}, init_module.ffi.allocator()) catch |err| return @intFromEnum(fromError(err, Operation.init));

    return @intFromEnum(ErrorCode.ok);
}
