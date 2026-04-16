// ── Imports ─────────────────────────────────────────────────────────────────────
const std = @import("std");

const states = @import("states.zig");

// ── Public types ────────────────────────────────────────────────────────────
// Main structure containing package metadata
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

// Parameters for the package preparation request: paths to the archive and output folder, and the checksum
pub const PrepareRequest = struct {
    pkg_path: []const u8,
    out_path: []const u8,
    checksum: []const u8,
};

// Listing specific backend errors when working with archives and metadata
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

// ── Inner FSM types ───────────────────────────────────────────────────────
// State Identifiers for the preparation process Finite State Machine (FSM)
pub const StateId = enum {
    verifying,
    extracting,
    reading_meta,
    done,
    failed,
};

// ── BackendFSM ───────────────────────────────────────────────────────
// A state machine context storing the transition stack, allocator, and parsing result
pub const BackendMachine = struct {
    request: PrepareRequest,

    meta: ?PackageMeta,

    stack: std.ArrayList(StateId),
    allocator: std.mem.Allocator,

    // Method for transitioning to a new state with history addition
    pub fn enter(self: *BackendMachine, id: StateId) !void {
        try self.stack.append(id);
        std.debug.print("[alpm → {s}]\n", .{@tagName(id)});
    }

    // Releasing resources (stack memory) occupied by the state machine
    pub fn deinit(self: *BackendMachine) void {
        self.stack.deinit();
    }

    // The entry and launch point of the machine, responsible for returning the correct result
    pub fn run(request: PrepareRequest, allocator: std.mem.Allocator) !PackageMeta {
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
};

// ── Public API ─────────────────────────────────────────────────────────────
// The main high-level function for initiating the package preparation process
pub fn prepare(request: PrepareRequest, allocator: std.mem.Allocator) !PackageMeta {
    return BackendMachine.run(request, allocator);
}

// ── FFI types ──────────────────────────────────────────────────────────────────
// A helper structure for passing data slices via C FFI
const CSlice = extern struct {
    ptr: [*]const u8,
    len: usize,

    // Converts a CSlice struct into a standard Zig slice []const u8.
    fn toSlice(self: CSlice) []const u8 {
        return self.ptr[0..self.len];
    }

    // Creates a CSlice instance from a standard Zig slice []const u8.
    fn fromSlice(s: []const u8) CSlice {
        return .{ .ptr = s.ptr, .len = s.len };
    }
};

// A C-compatible representation of package metadata for export to other languages
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

// C-compatible request parameter structure for use in FFI
const CPrepareRequest = extern struct {
    pkg_path: CSlice,
    out_path: CSlice,
    checksum: CSlice,
};

// The main allocator for the entire library
var gpa = std.heap.GeneralPurposeAllocator(.{}){};

// ── FFI экспорты ──────────────────────────────────────────────────────────────
// An exported C function (FFI) for initiating the preparation process from external code
pub export fn upac_backend_prepare(request: *const CPrepareRequest, out_meta: *CPackageMeta) callconv(.C) i32 {
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

// A function for safely clearing metadata memory allocated on the Zig side
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
