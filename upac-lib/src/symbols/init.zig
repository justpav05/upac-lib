// ── Imports ─────────────────────────────────────────────────────────────────────
const init_module = @import("upac-init");
const std = init_module.std;

const CRepoMode = init_module.ffi.CRepoMode;
const CInitRequest = init_module.ffi.CInitRequest;

const ErrorCode = init_module.ffi.ErrorCode;
const Operation = init_module.ffi.Operation;
const fromError = init_module.ffi.fromError;

// Initializes system paths and the OSTree repository in the selected mode (archive, bare, etc.)
pub fn init(init_request_c: CInitRequest) callconv(.c) i32 {
    init_request_c.validate() catch return @intFromEnum(fromError(error.InvalidEntry, Operation.init));

    var arena_allocator = std.heap.ArenaAllocator.init(init_module.ffi.allocator());
    defer arena_allocator.deinit();

    const repo_mode: init_module.RepoMode = switch (init_request_c.repo_mode) {
        .archive => .archive,
        .bare => .bare,
        .bare_user => .bare_user,
    };

    const addition_prefixes_c = init_request_c.addition_prefixes.toSlice();
    const addition_prefixes = init_module.ffi.allocator().alloc([]const u8, addition_prefixes_c.len) catch return @intFromEnum(fromError(error.OutOfMemory, Operation.init));
    defer init_module.ffi.allocator().free(addition_prefixes);

    for (addition_prefixes_c, 0..) |prefix, index| addition_prefixes[index] = prefix.toSlice();

    const repo_path_c = arena_allocator.allocator().dupeZ(u8, init_request_c.repo_path.toSlice()) catch return @intFromEnum(fromError(error.AllocZFailed, Operation.uninstall));

    const root_path_c = arena_allocator.allocator().dupeZ(u8, init_request_c.root_path.toSlice()) catch return @intFromEnum(fromError(error.AllocZFailed, Operation.uninstall));

    const branch_c = arena_allocator.allocator().dupeZ(u8, init_request_c.branch.toSlice()) catch return @intFromEnum(fromError(error.AllocZFailed, Operation.uninstall));

    init_module.initSystem(repo_path_c, root_path_c, repo_mode, branch_c, init_request_c.prefix.toSlice(), addition_prefixes, init_module.ffi.allocator()) catch |err| return @intFromEnum(fromError(err, Operation.init));

    return @intFromEnum(ErrorCode.ok);
}
