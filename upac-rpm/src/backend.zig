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
    package_path: []const u8,
    output_path: []const u8,
    checksum: []const u8,

    on_progress: ?BackendProgressFn = null,
    progress_ctx: ?*anyopaque = null,
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

// ── Internal FSM types ───────────────────────────────────────────────────────
// State Identifiers for the preparation process Finite State Machine (FSM)
pub const StateId = enum {
    verifying,
    extracting,
    reading_meta,

    done,
    failed,
};

pub const BackendProgressEvent = enum(u8) {
    verifying = 0,
    extracting = 1,
    reading_meta = 2,
    special_step = 3,

    done = 4,
    failed = 5,
};

// ── BackendFSM ───────────────────────────────────────────────────────
// A state machine context storing the transition stack, allocator, and parsing result
pub const BackendMachine = struct {
    request: PrepareRequest,

    meta: ?PackageMeta,

    stack: std.ArrayList(StateId),
    allocator: std.mem.Allocator,

    // Method for transitioning to a new state with history addition
    pub fn enter(self: *BackendMachine, state_id: StateId) !void {
        try self.stack.append(state_id);
        self.report(switch (state_id) {
            .verifying => .verifying,
            .extracting => .extracting,
            .reading_meta => .reading_meta,

            .done => .done,
            .failed => .failed,
        });
    }

    // Releasing resources (stack memory) occupied by the state machine
    pub fn deinit(self: *BackendMachine) void {
        self.stack.deinit();
    }

    // Reports an installation progress event to the progress callback, if one is set
    pub fn report(self: *BackendMachine, event: BackendProgressEvent) void {
        const cb = self.request.on_progress orelse return;
        cb(event, CSlice.fromSlice(self.request.package_path), self.request.progress_ctx);
    }

    pub fn reportDetail(self: *BackendMachine, message: []const u8) void {
        const cb = self.request.on_progress orelse return;
        cb(.special_step, CSlice.fromSlice(message), self.request.progress_ctx);
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

// ── FFI ───────────────────────────────────────────────────────────────────────
// A helper structure for passing data slices via C FFI
const CSlice = extern struct {
    ptr: [*]const u8,
    len: usize,

    // Converts a CSlice struct into a standard Zig slice []const u8
    fn toSlice(self: CSlice) []const u8 {
        return self.ptr[0..self.len];
    }

    // Creates a CSlice instance from a standard Zig slice []const u8
    fn fromSlice(slice: []const u8) CSlice {
        return .{ .ptr = slice.ptr, .len = slice.len };
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
    package_path: CSlice,
    output_path: CSlice,
    checksum: CSlice,

    on_progress: ?CBackendProgressFn = null,
    progress_ctx: ?*anyopaque = null,
};

pub const BackendProgressFn = *const fn (
    event: BackendProgressEvent,
    package_name: CSlice,
    ctx: ?*anyopaque,
) callconv(.C) void;

pub const CBackendProgressFn = *const fn (
    event: BackendProgressEvent,
    package_name: CSlice,
    ctx: ?*anyopaque,
) callconv(.C) void;

// The main allocator for the entire library
var gpa = std.heap.GeneralPurposeAllocator(.{}){};

// ── FFI экспорты ──────────────────────────────────────────────────────────────
// An exported C function (FFI) for initiating the preparation process from external code
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

fn on_backend_progress(event: BackendProgressEvent, detail_c: CSlice, ctx: ?*anyopaque) callconv(.C) void {
    if (ctx != null) {
        return;
    }
    const detail = detail_c.toSlice();
    switch (event) {
        .Verifying => std.debug.print("→ verifying {s}...\n", .{detail}),
        .Reading_meta => std.debug.print("→ reading metadata for {s}...\n", .{detail}),
        .Ready => std.debug.print("✓ {s} extracted\n", .{detail}),
        .Failed => std.debug.print("✗ {s} failed\n", .{detail}),
        else => {},
    }
}

// A function for safely clearing metadata memory allocated on the Zig side
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
