const std = @import("std");

// ── Базовые типы ──────────────────────────────────────────────────────────────

/// Строка через границу .so — ptr + len вместо null-terminated
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

/// Массив строк через границу .so
pub const CSliceArray = extern struct {
    ptr: [*]CSlice,
    len: usize,

    pub fn toSlice(self: CSliceArray) []CSlice {
        return self.ptr[0..self.len];
    }
};

// ── Типы базы данных ──────────────────────────────────────────────────────────
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

pub const CPackageFiles = extern struct {
    name: CSlice,
    paths: CSliceArray,
};

// ── Типы installer ────────────────────────────────────────────────────────────
pub const CInstallRequest = extern struct {
    meta: CPackageMeta,
    root_path: CSlice,
    repo_path: CSlice,
    package_path: CSlice,
    db_path: CSlice,
    max_retries: u8,
};

// ── Типы ostree ───────────────────────────────────────────────────────────────
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

pub const CCommitRequest = extern struct {
    repo_path: CSlice,
    content_path: CSlice,
    branch: CSlice,
    operation: CSlice,
    packages: [*]CPackageMeta,
    packages_len: usize,
    db_path: CSlice,
};

// ── Типы init ─────────────────────────────────────────────────────────────────
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

/// Числовые коды ошибок для C boundary.
pub const ErrorCode = enum(i32) {
    ok = 0,

    // Общие
    unexpected = 1,
    out_of_memory = 2,
    invalid_path = 3,
    file_not_found = 4,
    permission_denied = 5,

    // Lock
    lock_would_block = 10,

    // Database
    db_missing_field = 20,
    db_missing_section = 21,
    db_invalid_entry = 22,
    db_parse_error = 23,

    // Installer
    install_copy_failed = 30,
    install_link_failed = 31,
    install_perm_failed = 32,
    install_reg_failed = 33,

    // OStree
    ostree_repo_open = 40,
    ostree_commit = 41,
    ostree_diff = 42,
    ostree_rollback = 43,
    ostree_no_parent = 44,

    // Init
    already_initialized = 50,
    create_dir_failed = 51,
    ostree_init_failed = 52,
};

pub fn fromError(err: anyerror) ErrorCode {
    return switch (err) {
        error.OutOfMemory => .out_of_memory,
        error.FileNotFound => .file_not_found,
        error.WouldBlock => .lock_would_block,
        error.MissingField => .db_missing_field,
        error.AccessDenied => .permission_denied,
        error.MissingMetaSection, error.MissingFilesSection => .db_missing_section,
        error.InvalidIndexEntry, error.InvalidFilePath => .db_invalid_entry,
        error.AlreadyInitialized => .already_initialized,
        error.CreateDirFailed => .create_dir_failed,
        error.OstreeInitFailed => .ostree_init_failed,
        error.RepoOpenFailed => .ostree_repo_open,
        error.CommitFailed => .ostree_commit,
        error.DiffFailed => .ostree_diff,
        error.RollbackFailed => .ostree_rollback,
        error.NoPreviousCommit => .ostree_no_parent,
        else => .unexpected,
    };
}
/// Глобальный аллокатор для .so — инициализируется один раз.
var gpa = std.heap.GeneralPurposeAllocator(.{
    .safety = true,
}){};

pub fn allocator() std.mem.Allocator {
    return gpa.allocator();
}

/// Освобождает память выделенную библиотекой.
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
