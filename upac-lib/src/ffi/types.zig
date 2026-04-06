const std = @import("std");

pub const CSlice = extern struct {
    ptr: [*]const u8,
    len: usize,

    pub fn fromSlice(slice: []const u8) CSlice {
        return .{ .ptr = slice.ptr, .len = slice.len };
    }

    pub fn toSlice(self: CSlice) []const u8 {
        return self.ptr[0..self.len];
    }

    pub fn isEmpty(self: CSlice) bool {
        return self.len == 0;
    }
};

pub const CSliceArray = extern struct {
    ptr: [*]CSlice,
    len: usize,

    pub fn toSlice(self: CSliceArray) []CSlice {
        return self.ptr[0..self.len];
    }
};

pub const CPackageMeta = extern struct {
    name: CSlice,
    version: CSlice,
    author: CSlice,
    description: CSlice,
    license: CSlice,
    url: CSlice,
    installed_at: i64,
    checksum: CSlice,
};

pub const CInstallRequest = extern struct {
    meta: CPackageMeta,
    package_temp_path: CSlice,
    package_checksum: CSlice,
    repo_path: CSlice,
    index_path: CSlice,
    db_path: CSlice,
    branch: CSlice,
    checkout_path: CSlice,
    max_retries: u8,
};

pub const CUninstallRequest = extern struct {
    package_name: CSlice,
    repo_path: CSlice,
    db_path: CSlice,
    branch: CSlice,
    checkout_path: CSlice,
    max_retries: u8,
};

pub const CDiffKind = enum(u8) {
    added = 0,
    removed = 1,
    modified = 2,
};

pub const CDiffEntry = extern struct {
    path: CSlice,
    kind: CDiffKind,
};

pub const CDiffArray = extern struct {
    ptr: [*]CDiffEntry,
    len: usize,

    pub fn toSlice(self: CDiffArray) []CDiffEntry {
        return self.ptr[0..self.len];
    }
};

pub const CCommitEntry = extern struct {
    checksum: CSlice,
    subject: CSlice,
};

pub const CCommitArray = extern struct {
    ptr: [*]CCommitEntry,
    len: usize,

    pub fn toSlice(self: CCommitArray) []CCommitEntry {
        return self.ptr[0..self.len];
    }
};

pub const CRollbackRequest = extern struct {
    repo_path: CSlice,
    branch: CSlice,
    commit_hash: CSlice,
    checkout_path: CSlice,
};

pub const CSystemPaths = extern struct {
    ostree_path: CSlice,
    repo_path: CSlice,
    db_path: CSlice,
};

pub const CRepoMode = enum(u8) {
    archive = 0,
    bare = 1,
    bare_user = 2,
};

pub const ErrorCode = enum(i32) {
    ok = 0,

    unexpected = 1,
    out_of_memory = 2,
    invalid_path = 3,
    file_not_found = 4,
    permission_denied = 5,

    lock_would_block = 10,

    db_missing_field = 20,
    db_missing_section = 21,
    db_invalid_entry = 22,
    db_parse_error = 23,

    install_already_installed = 30,
    install_failed = 31,

    uninstall_not_found = 40,
    uninstall_failed = 41,

    ostree_repo_open = 50,
    ostree_commit = 51,
    ostree_diff = 52,
    ostree_rollback = 53,
    ostree_no_parent = 54,

    already_initialized = 60,
    create_dir_failed = 61,
    ostree_init_failed = 62,
};

pub fn fromError(err: anyerror) ErrorCode {
    return switch (err) {
        error.OutOfMemory => .out_of_memory,
        error.FileNotFound => .file_not_found,
        error.WouldBlock => .lock_would_block,
        error.AccessDenied => .permission_denied,
        error.AlreadyInstalled => .install_already_installed,
        error.PackageNotFound => .uninstall_not_found,
        error.RepoOpenFailed => .ostree_repo_open,
        error.MaxRetriesExceeded => .install_failed,
        error.AlreadyInitialized => .already_initialized,
        error.CreateDirFailed => .create_dir_failed,
        error.OstreeInitFailed => .ostree_init_failed,
        error.RollbackFailed => .ostree_rollback,
        error.NoPreviousCommit => .ostree_no_parent,
        error.DiffFailed => .ostree_diff,
        else => .unexpected,
    };
}

var gpa = std.heap.GeneralPurposeAllocator(.{ .safety = true }){};

pub fn allocator() std.mem.Allocator {
    return gpa.allocator();
}

pub export fn upac_free(ptr: *anyopaque, len: usize) callconv(.C) void {
    const slice = @as([*]u8, @ptrCast(ptr))[0..len];
    gpa.allocator().free(slice);
}

pub export fn upac_deinit() callconv(.C) void {
    const result = gpa.deinit();
    if (result == .leak) {
        std.debug.print("[upac] WARNING: memory leak detected\n", .{});
    }
}
