// ── Imports ─────────────────────────────────────────────────────────────────────
const std = @import("std");

// ── Reimports types ─────────────────────────────────────────────────────────────────────
const types = @import("types.zig");

pub const Package = types.Package;
pub const PackageMeta = types.PackageMeta;
pub const PackageFile = types.PackageFile;

pub const PackageDiffKind = types.PackageDiffKind;
pub const PackageDiffEntry = types.PackageDiffEntry;

pub const AttributedDiffEntry = types.AttributedDiffEntry;

pub const CommitEntry = types.CommitEntry;

pub const DiffKind = types.DiffKind;
pub const DiffEntry = types.DiffEntry;

pub const InstallProgressEvent = types.InstallProgressEvent;
pub const UninstallProgressEvent = types.UninstallProgressEvent;

// ── Reimports errors ─────────────────────────────────────────────────────────────────────
const errors = @import("errors.zig");
pub const ErrorCode = errors.ErrorCode;
pub const Operation = errors.Operation;
pub const fromError = errors.fromError;

// A C-compatible slice analogue. It stores a pointer to the data and its length. It allows for easy conversion of data between Zig and an external interface
pub const CSlice = extern struct {
    ptr: [*]const u8,
    len: usize,

    // Converts a native Zig slice into a C-compatible CSlice struct, packaging the pointer and length
    pub fn fromSlice(slice: []const u8) CSlice {
        return .{ .ptr = slice.ptr, .len = slice.len };
    }

    // It performs the inverse operation—reconstructing a safe Zig slice from data received via a C interface—so that it can be manipulated using standard language constructs
    pub fn toSlice(self: CSlice) []const u8 {
        return self.ptr[0..self.len];
    }

    // A simple check to determine whether a passed string or data array is empty (i.e., has zero length)
    pub fn isEmpty(self: CSlice) bool {
        return self.len == 0;
    }
};

// A wrapper over pointers to arrays of structures used to pass dynamic lists across the C boundary
pub const CSliceArray = extern struct {
    ptr: [*]CSlice,
    len: usize,

    pub fn toSlice(self: CSliceArray) []CSlice {
        return self.ptr[0..self.len];
    }
};

pub const CPackageDiffKind = enum(u8) {
    added = 0,
    removed = 1,
    updated = 2,
};

pub const CPackageEntry = extern struct {
    meta: CPackageMeta,
    temp_path: CSlice,
    checksum: CSlice,
};

// A packet metadata structure adapted for transmission via C
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

pub const CPackageMetaArray = extern struct {
    ptr: [*]CPackageMeta,
    len: usize,

    pub fn toSlice(self: CPackageMetaArray) []CPackageMeta {
        return self.ptr[0..self.len];
    }
};

// Parameter sets for the сorresponding operation — Installation
pub const CInstallRequest = extern struct {
    packages: [*]const CPackageEntry,
    packages_len: usize,

    repo_path: CSlice,
    root_path: CSlice,
    db_path: CSlice,

    branch: CSlice,

    on_progress: ?CInstallProgressFn = null,
    progress_ctx: ?*anyopaque = null,

    max_retries: u8,
};

pub const InstallProgressFn = *const fn (
    event: InstallProgressEvent,
    package_name: CSlice,
    ctx: ?*anyopaque,
) callconv(.C) void;

pub const CInstallProgressFn = *const fn (
    event: InstallProgressEvent,
    package_name: CSlice,
    ctx: ?*anyopaque,
) callconv(.C) void;

// // Parameter sets for the сorresponding operation — Uninstallation
pub const CUninstallRequest = extern struct {
    package_names: [*]const CSlice,
    package_names_len: usize,

    repo_path: CSlice,
    root_path: CSlice,
    db_path: CSlice,

    branch: CSlice,

    on_progress: ?CUninstallProgressFn = null,
    progress_ctx: ?*anyopaque = null,

    max_retries: u8,
};

pub const UninstallProgressFn = *const fn (
    event: UninstallProgressEvent,
    package_name: CSlice,
    ctx: ?*anyopaque,
) callconv(.C) void;

pub const CUninstallProgressFn = *const fn (
    event: UninstallProgressEvent,
    package_name: CSlice,
    ctx: ?*anyopaque,
) callconv(.C) void;

// Enumeration of file system change types (added, deleted, modified)
pub const CDiffKind = enum(u8) {
    added = 0,
    removed = 1,
    modified = 2,
};

//
pub const CDiffEntry = extern struct {
    path: CSlice,
    kind: CDiffKind,
};

// A wrapper over pointers to arrays of structures used to pass dynamic lists across the C boundary
pub const CDiffArray = extern struct {
    ptr: [*]CDiffEntry,
    len: usize,

    pub fn toSlice(self: CDiffArray) []CDiffEntry {
        return self.ptr[0..self.len];
    }
};

pub const CPackageDiffEntry = extern struct {
    name: CSlice,
    kind: CPackageDiffKind,
};

pub const CPackageDiffArray = extern struct {
    ptr: [*]CPackageDiffEntry,
    len: usize,

    pub fn toSlice(self: CPackageDiffArray) []CPackageDiffEntry {
        return self.ptr[0..self.len];
    }
};

pub const CAttributedDiffEntry = extern struct {
    path: CSlice,
    kind: CDiffKind,
    package_name: CSlice,
};

pub const CAttributedDiffArray = extern struct {
    ptr: [*]CAttributedDiffEntry,
    len: usize,

    pub fn toSlice(self: CAttributedDiffArray) []CAttributedDiffEntry {
        return self.ptr[0..self.len];
    }
};

//
pub const CCommitEntry = extern struct {
    checksum: CSlice,
    subject: CSlice,
};

// A wrapper over pointers to arrays of structures used to pass dynamic lists across the C boundary
pub const CCommitArray = extern struct {
    ptr: [*]CCommitEntry,
    len: usize,

    pub fn toSlice(self: CCommitArray) []CCommitEntry {
        return self.ptr[0..self.len];
    }
};

// // Parameter sets for the сorresponding operation — Rollback
pub const CRollbackRequest = extern struct {
    root_path: CSlice,
    repo_path: CSlice,

    branch: CSlice,

    commit_hash: CSlice,
};

// A set of paths required to initialize the system
pub const CSystemPaths = extern struct {
    repo_path: CSlice,
    root_path: CSlice,
};

// Request structure for initializing the system with branch specification
pub const CInitRequest = extern struct {
    system_paths: CSystemPaths,
    repo_mode: CRepoMode,
    branch: CSlice,
};

// Defines the operating mode of the OSTree repository
pub const CRepoMode = enum(u8) {
    archive = 0,
    bare = 1,
    bare_user = 2,
};

var gpa = std.heap.GeneralPurposeAllocator(.{ .safety = true }){};

pub fn allocator() std.mem.Allocator {
    return gpa.allocator();
}

pub fn deinit() void {
    const result = gpa.deinit();
    if (result == .leak) std.debug.print("[upac] WARNING: memory leak detected\n", .{});
}
