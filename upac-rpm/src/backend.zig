const std = @import("std");

const states = @import("states.zig");

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
    package_path: []const u8,
    output_path: []const u8,
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

pub const StateId = enum {
    verifying,
    extracting,
    reading_meta,
    done,
    failed,
};

pub const BackendMachine = struct {
    request: PrepareRequest,
    stack: std.ArrayList(StateId),
    allocator: std.mem.Allocator,
    meta: ?PackageMeta,

    pub fn enter(self: *BackendMachine, state_id: StateId) !void {
        try self.stack.append(state_id);
        std.debug.print("[rpm → {s}]\n", .{@tagName(state_id)});
    }

    pub fn deinit(self: *BackendMachine) void {
        self.stack.deinit();
    }
};

pub fn prepare(request: PrepareRequest, allocator: std.mem.Allocator) !PackageMeta {
    var machine = BackendMachine{
        .request = request,
        .stack = std.ArrayList(StateId).init(allocator),
        .allocator = allocator,
        .meta = null,
    };
    defer machine.deinit();

    try states.stateVerifying(&machine);

    return machine.meta orelse BackendError.InvalidPackage;
}

// ── FFI ───────────────────────────────────────────────────────────────────────
const CSlice = extern struct {
    ptr: [*]const u8,
    len: usize,

    fn toSlice(self: CSlice) []const u8 {
        return self.ptr[0..self.len];
    }

    fn fromSlice(slice: []const u8) CSlice {
        return .{ .ptr = slice.ptr, .len = slice.len };
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
    package_path: CSlice,
    output_path: CSlice,
    checksum: CSlice,
};

var gpa = std.heap.GeneralPurposeAllocator(.{}){};

pub export fn upac_backend_prepare(
    request: *const CPrepareRequest,
    out_meta: *CPackageMeta,
) callconv(.C) i32 {
    const allocator = gpa.allocator();

    const zig_request = PrepareRequest{
        .package_path = request.package_path.toSlice(),
        .output_path = request.output_path.toSlice(),
        .checksum = request.checksum.toSlice(),
    };

    const package_meta = prepare(zig_request, allocator) catch |err| {
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
        .name = CSlice.fromSlice(package_meta.name),
        .version = CSlice.fromSlice(package_meta.version),
        .author = CSlice.fromSlice(package_meta.author),
        .description = CSlice.fromSlice(package_meta.description),
        .license = CSlice.fromSlice(package_meta.license),
        .url = CSlice.fromSlice(package_meta.url),
        .installed_at = package_meta.installed_at,
        .checksum = CSlice.fromSlice(package_meta.checksum),
    };

    return 0;
}

pub export fn upac_backend_meta_free(package_meta: *CPackageMeta) callconv(.C) void {
    const allocator = gpa.allocator();
    allocator.free(package_meta.name.toSlice());
    allocator.free(package_meta.version.toSlice());
    allocator.free(package_meta.author.toSlice());
    allocator.free(package_meta.description.toSlice());
    allocator.free(package_meta.license.toSlice());
    allocator.free(package_meta.url.toSlice());
    allocator.free(package_meta.checksum.toSlice());
}
