// ── Imports ─────────────────────────────────────────────────────────────────────
const init = @import("init.zig");
const ffi = init.ffi;

const CInitRequest = ffi.CInitRequest;

const ErrorCode = ffi.ErrorCode;
const Operation = ffi.Operation;
const fromError = ffi.fromError;

// Initializes system paths and the OSTree repository in the selected mode (archive, bare, etc.)
pub export fn upac_init(c_init_request: CInitRequest) callconv(.C) i32 {
    const system_paths = init.SystemPaths{
        .repo_path = c_init_request.system_paths.repo_path.toSlice(),
        .root_path = c_init_request.system_paths.root_path.toSlice(),
    };

    const repo_mode: init.RepoMode = switch (c_init_request.repo_mode) {
        .archive => .archive,
        .bare => .bare,
        .bare_user => .bare_user,
    };

    const branch = c_init_request.branch.toSlice();

    init.initSystem(system_paths, repo_mode, branch, ffi.allocator()) catch |err|
        return @intFromEnum(fromError(err, Operation.init));

    return @intFromEnum(ErrorCode.ok);
}
