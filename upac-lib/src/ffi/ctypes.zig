// ── Imports ─────────────────────────────────────────────────────────────────────
pub const std = @import("std");

pub const c_libs = @cImport({
    @cInclude("ostree.h");
    @cInclude("glib.h");
    @cInclude("gio/gio.h");
    @cInclude("fcntl.h");
    @cInclude("glib-unix.h");
    @cInclude("sys/statvfs.h");
});

pub var global_cancel = std.atomic.Value(bool).init(false);

// ── Reimports types ─────────────────────────────────────────────────────────────────────
const types = @import("types.zig");

pub const Package = types.Package;
pub const PackageMeta = types.PackageMeta;
pub const PackageFile = types.PackageFile;

pub const PackageDiffKind = types.PackageDiffKind;
pub const PackageDiffEntry = types.PackageDiffEntry;

pub const AttributedDiffEntry = types.AttributedDiffEntry;

pub const DiffKind = types.DiffKind;
pub const DiffEntry = types.DiffEntry;

pub const InstallStateId = types.InstallStateId;
pub const UninstallStateId = types.UninstallStateId;
pub const RollbackStateId = types.RollbackStateId;

pub const ListStateId = types.ListStateId;

// ── Reimports errors ─────────────────────────────────────────────────────────────────────
const errors = @import("errors.zig");
pub const ErrorCode = errors.ErrorCode;
pub const Operation = errors.Operation;
pub const fromError = errors.fromError;

// A C-compatible slice analogue. It stores a pointer to the data and its length. It allows for easy conversion of data between Zig and an external interface
pub const CSlice = extern struct {
    ptr: [*:0]const u8,
    len: usize,

    pub fn toSlice(self: CSlice) []const u8 {
        return self.ptr[0..self.len];
    }

    pub fn asZ(self: CSlice) [*:0]const u8 {
        return self.ptr;
    }

    pub fn fromSlice(slice: []const u8) CSlice {
        return .{ .ptr = @ptrCast(slice.ptr), .len = slice.len };
    }

    pub fn validate(self: CSlice) !void {
        if (self.ptr[self.len] != 0) return error.InvalidEntry;
        if (std.mem.len(self.ptr) != self.len) return error.InvalidEntry;
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

pub fn CArray(comptime T: type) type {
    return extern struct {
        ptr: [*]T,
        len: usize,

        pub fn toSlice(self: @This()) []T {
            return self.ptr[0..self.len];
        }
    };
}

pub const CPackageDiffKind = enum(u8) {
    added = 0,
    removed = 1,
    updated = 2,
};

pub const CPackageEntry = extern struct {
    struct_size: usize = @sizeOf(CPackageEntry),

    meta: *anyopaque,
    temp_path: CSlice,
    checksum: CSlice,

    pub fn validate(self: CPackageEntry) !void {
        if (self.struct_size != @sizeOf(CPackageEntry)) return error.AbiMismatch;

        if (@intFromPtr(self.meta) == 0) return error.InvalidEntry;
    }
};

// A packet metadata structure adapted for transmission via C
pub const CPackageMeta = extern struct {
    struct_size: usize = @sizeOf(CPackageMeta),

    name: CSlice,
    version: CSlice,
    architecture: CSlice,
    author: CSlice,
    description: CSlice,
    license: CSlice,
    url: CSlice,
    packager: CSlice,
    checksum: CSlice,
    size: u32,
    _padding: u32 = 0,
    installed_at: i64,

    pub fn validate(self: CPackageMeta) !void {
        if (self.struct_size != @sizeOf(CPackageMeta)) return error.AbiMismatch;
    }
};

pub const CMutatedRequest = extern struct {
    struct_size: usize = @sizeOf(CMutatedRequest),

    repo_path: CSlice,
    root_path: CSlice,
    db_path: CSlice,
    branch: CSlice,
    prefix_directory: CSlice,

    // Install
    packages: ?[*]const CPackageEntry = null,
    packages_count: usize = 0,

    // Uninstall
    package_names: ?[*]const CSlice = null,
    package_names_len: usize = 0,

    // Rollback
    commit_hash: CSlice,

    on_progress: ?*const fn (event: u32, package_name: CSlice, ctx: ?*anyopaque) callconv(.c) void = null,
    progress_ctx: ?*anyopaque = null,

    max_retries: u8 = 0,

    pub fn validate(self: CMutatedRequest) !void {
        if (self.struct_size != @sizeOf(CMutatedRequest)) return error.AbiMismatch;
        try self.repo_path.validate();
        try self.root_path.validate();
        try self.db_path.validate();
        try self.branch.validate();
        try self.prefix_directory.validate();
    }
};

// Request structure for initializing the system with branch specification
pub const CUnmutatedRequest = extern struct {
    struct_size: usize = @sizeOf(CUnmutatedRequest),

    repo_path: CSlice,
    root_path: CSlice,
    db_path: CSlice,
    branch: CSlice,
    prefix: CSlice,

    repo_mode: CRepoMode,

    pub fn validate(self: CUnmutatedRequest) !void {
        if (self.struct_size != @sizeOf(CUnmutatedRequest)) return error.AbiMismatch;
        _ = std.meta.intToEnum(CRepoMode, @intFromEnum(self.repo_mode)) catch return error.InvalidEntry;
        try self.repo_path.validate();
    }
};

pub const InstallProgressFn = *const fn (
    event: InstallStateId,
    package_name: CSlice,
    ctx: ?*anyopaque,
) callconv(.c) void;

pub const CInstallProgressFn = *const fn (
    event: InstallStateId,
    package_name: CSlice,
    ctx: ?*anyopaque,
) callconv(.c) void;

pub const UninstallProgressFn = *const fn (
    event: UninstallStateId,
    package_name: CSlice,
    ctx: ?*anyopaque,
) callconv(.c) void;

pub const CUninstallProgressFn = *const fn (
    event: UninstallStateId,
    package_name: CSlice,
    ctx: ?*anyopaque,
) callconv(.c) void;

pub const RollbackProgressFn = *const fn (
    event: RollbackStateId,
    package_name: CSlice,
    ctx: ?*anyopaque,
) callconv(.c) void;

pub const CRollbackProgressFn = *const fn (
    event: RollbackStateId,
    package_name: CSlice,
    ctx: ?*anyopaque,
) callconv(.c) void;

// Enumeration of file system change types (added, deleted, modified)
pub const CDiffKind = enum(u8) {
    added = 0,
    removed = 1,
    modified = 2,
};

//
pub const CDiffEntry = extern struct {
    struct_size: usize = @sizeOf(CDiffEntry),

    path: CSlice,
    kind: CDiffKind,

    pub fn validate(self: CDiffEntry) !void {
        if (self.struct_size != @sizeOf(CDiffEntry)) return error.AbiMismatch;
        _ = std.meta.intToEnum(CDiffKind, @intFromEnum(self.kind)) catch return error.InvalidEntry;
    }
};

pub const CPackageDiffEntry = extern struct {
    struct_size: usize = @sizeOf(CPackageDiffEntry),

    name: CSlice,
    kind: CPackageDiffKind,

    pub fn validate(self: CPackageDiffEntry) !void {
        if (self.struct_size != @sizeOf(CPackageDiffEntry)) return error.AbiMismatch;
        _ = std.meta.intToEnum(CPackageDiffKind, @intFromEnum(self.kind)) catch return error.InvalidEntry;
    }
};

pub const CAttributedDiffEntry = extern struct {
    struct_size: usize = @sizeOf(CAttributedDiffEntry),

    path: CSlice,
    kind: CDiffKind,
    package_name: CSlice,

    pub fn validate(self: CAttributedDiffEntry) !void {
        if (self.struct_size != @sizeOf(CAttributedDiffEntry)) return error.AbiMismatch;
        _ = std.meta.intToEnum(CPackageDiffKind, @intFromEnum(self.kind)) catch return error.InvalidEntry;
    }
};

//
pub const CCommitEntry = extern struct {
    struct_size: usize = @sizeOf(CCommitEntry),

    checksum: CSlice,
    subject: CSlice,

    pub fn validate(self: CCommitEntry) !void {
        if (self.struct_size != @sizeOf(CCommitEntry)) return error.AbiMismatch;
    }
};

// Defines the operating mode of the OSTree repository
pub const CRepoMode = enum(u8) {
    archive = 0,
    bare = 1,
    bare_user = 2,
};

var gpa = std.heap.GeneralPurposeAllocator(.{ .safety = true, .thread_safe = true }){};

pub fn allocator() std.mem.Allocator {
    return gpa.allocator();
}

pub fn isCancelRequested() bool {
    return global_cancel.load(.acquire);
}

pub fn deinit() void {
    const result = gpa.deinit();
    if (result == .leak) std.debug.print("[upac] WARNING: memory leak detected\n", .{});
}
