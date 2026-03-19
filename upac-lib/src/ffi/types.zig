const std = @import("std");

// ── Базовые типы ──────────────────────────────────────────────────────────────

/// Строка через границу .so — ptr + len вместо null-terminated
pub const CSlice = extern struct {
    ptr: [*]const u8,
    len: usize,

    pub fn fromSlice(s: []const u8) CSlice {
        return .{ .ptr = s.ptr, .len = s.len };
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
