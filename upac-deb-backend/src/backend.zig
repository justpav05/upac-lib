const std = @import("std");

const states = @import("states.zig");

// ── Публичные типы ────────────────────────────────────────────────────────────
pub const PackageMeta = struct {
    name: []const u8,
    version: []const u8,
    author: []const u8,
    description: []const u8,
    license: []const u8,
    url: []const u8,
    installed_at: i64,
    checksum: []const u8,
};

pub const PrepareRequest = struct {
    pkg_path: []const u8,
    out_path: []const u8,
    checksum: []const u8,
};

pub const BackendError = error{
    ChecksumMismatch,
    ExtractionFailed,
    MetadataNotFound,
    InvalidPackage,
    ReadFailed,
    ArchiveOpenFailed,
    ArchiveReadFailed,
    ArchiveExtractFailed,
};

// ── Внутренние типы FSM ───────────────────────────────────────────────────────
pub const StateId = enum {
    verifying,
    verifying_files,
    extracting,
    reading_meta,
    done,
    failed,
};

pub const Machine = struct {
    request: PrepareRequest,
    stack: std.ArrayList(StateId),
    allocator: std.mem.Allocator,
    meta: ?PackageMeta,

    pub fn enter(self: *Machine, id: StateId) !void {
        try self.stack.append(id);
        std.debug.print("[arch → {s}]\n", .{@tagName(id)});
    }

    pub fn deinit(self: *Machine) void {
        self.stack.deinit();
    }
};

// ── Публичное API ─────────────────────────────────────────────────────────────
pub fn prepare(request: PrepareRequest, allocator: std.mem.Allocator) !PackageMeta {
    var machine = Machine{
        .request = request,
        .stack = std.ArrayList(StateId).init(allocator),
        .allocator = allocator,
        .meta = null,
    };
    defer machine.deinit();

    try states.stateVerifying(&machine);

    return machine.meta orelse BackendError.InvalidPackage;
}

// ── FFI типы ──────────────────────────────────────────────────────────────────
const CSlice = extern struct {
    ptr: [*]const u8,
    len: usize,

    fn toSlice(self: CSlice) []const u8 {
        return self.ptr[0..self.len];
    }

    fn fromSlice(s: []const u8) CSlice {
        return .{ .ptr = s.ptr, .len = s.len };
    }
};

const CPackageMeta = extern struct {
    name: CSlice,
    version: CSlice,
    author: CSlice,
    description: CSlice,
    license: CSlice,
    url: CSlice,
    installed_at: i64,
    checksum: CSlice,
};

const CPrepareRequest = extern struct {
    pkg_path: CSlice,
    out_path: CSlice,
    checksum: CSlice,
};

var gpa = std.heap.GeneralPurposeAllocator(.{}){};

// ── FFI экспорты ──────────────────────────────────────────────────────────────
pub export fn upac_backend_prepare(
    request: *const CPrepareRequest,
    out_meta: *CPackageMeta,
) callconv(.C) i32 {
    const allocator = gpa.allocator();

    const zig_request = PrepareRequest{
        .pkg_path = request.pkg_path.toSlice(),
        .out_path = request.out_path.toSlice(),
        .checksum = request.checksum.toSlice(),
    };

    const meta = prepare(zig_request, allocator) catch |err| {
        return switch (err) {
            BackendError.ChecksumMismatch => 1,
            BackendError.ExtractionFailed => 2,
            BackendError.MetadataNotFound => 3,
            BackendError.InvalidPackage => 4,
            BackendError.ArchiveOpenFailed => 5,
            BackendError.ArchiveReadFailed => 6,
            BackendError.ArchiveExtractFailed => 7,
            BackendError.ReadFailed => 8,
            else => 99,
        };
    };

    out_meta.* = CPackageMeta{
        .name = CSlice.fromSlice(meta.name),
        .version = CSlice.fromSlice(meta.version),
        .author = CSlice.fromSlice(meta.author),
        .description = CSlice.fromSlice(meta.description),
        .license = CSlice.fromSlice(meta.license),
        .url = CSlice.fromSlice(meta.url),
        .installed_at = meta.installed_at,
        .checksum = CSlice.fromSlice(meta.checksum),
    };

    return 0;
}

pub export fn upac_backend_meta_free(meta: *CPackageMeta) callconv(.C) void {
    const allocator = gpa.allocator();
    allocator.free(meta.name.toSlice());
    allocator.free(meta.version.toSlice());
    allocator.free(meta.author.toSlice());
    allocator.free(meta.description.toSlice());
    allocator.free(meta.license.toSlice());
    allocator.free(meta.url.toSlice());
    allocator.free(meta.checksum.toSlice());
}
