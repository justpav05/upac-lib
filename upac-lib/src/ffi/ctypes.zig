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

pub const InstallStateId = types.InstallStateId;
pub const UninstallStateId = types.UninstallStateId;
pub const RollbackStateId = types.RollbackStateId;

// ── Reimports errors ─────────────────────────────────────────────────────────────────────
const errors = @import("errors.zig");
pub const ErrorCode = errors.ErrorCode;
pub const Operation = errors.Operation;
pub const fromError = errors.fromError;

// A C-compatible slice analogue. It stores a pointer to the data and its length. It allows for easy conversion of data between Zig and an external interface
pub const CSlice = extern struct {
    ptr: ?[*]const u8,
    len: usize,

    // Converts a native Zig slice into a C-compatible CSlice struct, packaging the pointer and length
    pub fn fromSlice(slice: []const u8) CSlice {
        return .{ .ptr = slice.ptr, .len = slice.len };
    }

    // It performs the inverse operation—reconstructing a safe Zig slice from data received via a C interface—so that it can be manipulated using standard language constructs
    pub fn toSlice(self: CSlice) []const u8 {
        const ptr = self.ptr orelse return "";

        if (self.len > std.posix.PATH_MAX) return "";

        return ptr[0..self.len];
    }

    // A simple check to determine whether a passed string or data array is empty (i.e., has zero length)
    pub fn isEmpty(self: CSlice) bool {
        return self.len == 0 or self.ptr == null;
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

    pub fn validate(self: CPackageEntry) !void {
        try self.meta.validate();

        if (self.temp_path.isEmpty()) return error.InvalidEntry;
        if (self.checksum.isEmpty()) return error.InvalidEntry;
    }
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

    pub fn validate(self: CPackageMeta) !void {
        if (self.name.isEmpty()) return error.InvalidEntry;
        if (self.version.isEmpty()) return error.InvalidEntry;
        if (self.author.isEmpty()) return error.InvalidEntry;
        if (self.license.isEmpty()) return error.InvalidEntry;
        if (self.checksum.isEmpty()) return error.InvalidEntry;
    }
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
    struct_size: usize = @sizeOf(CInstallRequest),

    packages: ?[*]const CPackageEntry,
    packages_count: usize,

    repo_path: CSlice,
    root_path: CSlice,
    db_path: CSlice,

    branch: CSlice,
    prefix_directory: CSlice,

    on_progress: ?CInstallProgressFn = null,
    progress_ctx: ?*anyopaque = null,

    max_retries: u8,

    pub fn validate(self: CInstallRequest) !void {
        if (self.struct_size != @sizeOf(CInstallRequest)) return error.AbiMismatch;

        if (self.packages_count > 0 and self.packages == null) return error.InvalidEntry;

        if (self.repo_path.isEmpty()) return error.InvalidEntry;
        if (self.root_path.isEmpty()) return error.InvalidEntry;
        if (self.db_path.isEmpty()) return error.InvalidEntry;
        if (self.branch.isEmpty()) return error.InvalidEntry;
        if (self.prefix_directory.isEmpty()) return error.InvalidEntry;

        if (self.packages) |pkgs| {
            for (pkgs[0..self.packages_count]) |pkg| try pkg.validate();
        }
    }
};

pub const InstallProgressFn = *const fn (
    event: InstallStateId,
    package_name: CSlice,
    ctx: ?*anyopaque,
) callconv(.C) void;

pub const CInstallProgressFn = *const fn (
    event: InstallStateId,
    package_name: CSlice,
    ctx: ?*anyopaque,
) callconv(.C) void;

// // Parameter sets for the сorresponding operation — Uninstallation
pub const CUninstallRequest = extern struct {
    struct_size: usize = @sizeOf(CUninstallRequest),

    package_names: ?[*]const CSlice,
    package_names_len: usize,

    repo_path: CSlice,
    root_path: CSlice,
    db_path: CSlice,

    branch: CSlice,
    prefix_directory: CSlice,

    on_progress: ?CUninstallProgressFn = null,
    progress_ctx: ?*anyopaque = null,

    max_retries: u8,

    pub fn validate(self: CUninstallRequest) !void {
        if (self.struct_size != @sizeOf(CUninstallRequest)) return error.AbiMismatch;

        if (self.package_names_len > 0 and self.package_names == null) return error.InvalidEntry;

        if (self.repo_path.isEmpty()) return error.InvalidEntry;
        if (self.root_path.isEmpty()) return error.InvalidEntry;
        if (self.db_path.isEmpty()) return error.InvalidEntry;
        if (self.branch.isEmpty()) return error.InvalidEntry;
        if (self.prefix_directory.isEmpty()) return error.InvalidEntry;

        if (self.package_names) |names| {
            for (names[0..self.package_names_len]) |name| {
                if (name.isEmpty()) return error.InvalidEntry;
            }
        }
    }
};

pub const UninstallProgressFn = *const fn (
    event: UninstallStateId,
    package_name: CSlice,
    ctx: ?*anyopaque,
) callconv(.C) void;

pub const CUninstallProgressFn = *const fn (
    event: UninstallStateId,
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
    struct_size: usize = @sizeOf(CRollbackRequest),

    root_path: CSlice,
    repo_path: CSlice,

    branch: CSlice,
    prefix: CSlice,

    commit_hash: CSlice,

    pub fn validate(self: CRollbackRequest) !void {
        if (self.struct_size != @sizeOf(CRollbackRequest)) return error.AbiMismatch;

        if (self.root_path.isEmpty()) return error.InvalidEntry;
        if (self.repo_path.isEmpty()) return error.InvalidEntry;

        if (self.branch.isEmpty()) return error.InvalidEntry;
        if (self.commit_hash.isEmpty()) return error.InvalidEntry;
    }
};

pub const RollbackProgressFn = *const fn (
    event: RollbackStateId,
    package_name: CSlice,
    ctx: ?*anyopaque,
) callconv(.C) void;

pub const CRollbackProgressFn = *const fn (
    event: RollbackStateId,
    package_name: CSlice,
    ctx: ?*anyopaque,
) callconv(.C) void;

// Request structure for initializing the system with branch specification
pub const CInitRequest = extern struct {
    struct_size: usize = @sizeOf(CInitRequest),

    repo_path: CSlice,
    root_path: CSlice,

    prefix: CSlice,
    addition_prefixes: CSliceArray,

    repo_mode: CRepoMode,
    branch: CSlice,

    pub fn validate(self: CInitRequest) !void {
        if (self.struct_size != @sizeOf(CInitRequest)) return error.AbiMismatch;

        if (self.repo_path.isEmpty()) return error.InvalidEntry;
        if (self.root_path.isEmpty()) return error.InvalidEntry;
        if (self.prefix.isEmpty()) return error.InvalidEntry;
        if (self.branch.isEmpty()) return error.InvalidEntry;

        _ = std.meta.intToEnum(CRepoMode, @intFromEnum(self.repo_mode)) catch return error.InvalidEntry;

        for (self.addition_prefixes.toSlice()) |p| {
            if (p.isEmpty()) return error.InvalidEntry;
        }
    }
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
