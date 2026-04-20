// ── Imports ─────────────────────────────────────────────────────────────────────
const init = @import("init.zig");
const std = init.std;

const CRepoMode = init.ffi.CRepoMode;
const CInitRequest = init.ffi.CInitRequest;

const ErrorCode = init.ffi.ErrorCode;
const Operation = init.ffi.Operation;
const fromError = init.ffi.fromError;

// Initializes system paths and the OSTree repository in the selected mode (archive, bare, etc.)
pub export fn upac_init(init_request_c: CInitRequest) callconv(.C) i32 {
    init_request_c.validate() catch return @intFromEnum(fromError(error.InvalidEntry, Operation.init));

    const repo_mode: init.RepoMode = switch (init_request_c.repo_mode) {
        .archive => .archive,
        .bare => .bare,
        .bare_user => .bare_user,
    };

    const addition_prefixes_c = init_request_c.addition_prefixes.toSlice();
    const addition_prefixes = init.ffi.allocator().alloc([]const u8, addition_prefixes_c.len) catch return @intFromEnum(fromError(error.OutOfMemory, Operation.init));
    defer init.ffi.allocator().free(addition_prefixes);

    for (addition_prefixes_c, 0..) |prefix, index| addition_prefixes[index] = prefix.toSlice();

    init.initSystem(init_request_c.repo_path.toSlice(), init_request_c.root_path.toSlice(), repo_mode, init_request_c.branch.toSlice(), init_request_c.prefix.toSlice(), addition_prefixes, init.ffi.allocator()) catch |err| return @intFromEnum(fromError(err, Operation.init));

    return @intFromEnum(ErrorCode.ok);
}
