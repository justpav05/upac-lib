// ── Imports ─────────────────────────────────────────────────────────────────────
const std = @import("std");

const states = @import("states.zig");
const stateFailed = states.stateFailed;

// ── Public types ────────────────────────────────────────────────────────────
// Main structure containing package metadata
pub const PackageMeta = struct {
    name: []const u8,
    version: []const u8,
    size: u32,
    author: []const u8,
    description: []const u8,
    license: []const u8,
    arch: []const u8,
    url: []const u8,
    packager: []const u8,
    installed_at: i64,
    checksum: []const u8,
};

// Parameters for the package preparation request: paths to the archive and output folder, and the checksum
pub const PrepareRequest = struct {
    package_path: []const u8,
    temp_dir: []const u8,
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
    OutOfMemory,
    TempDirFailed,
    AllocZFailed,
    Cancelled,
};

var cancel_requested = std.atomic.Value(bool).init(false);

fn backendSignalHandler(sig: c_int) callconv(.C) void {
    _ = sig;
    cancel_requested.store(true, .release);
}

// ── Internal FSM types ───────────────────────────────────────────────────────
// State Identifiers for the preparation process Finite State Machine (FSM)
pub const StateId = enum(u8) {
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

    temp_path: ?[:0]const u8 = null,

    stack: std.ArrayList(StateId),
    allocator: std.mem.Allocator,

    // Method for transitioning to a new state with history addition
    pub fn enter(self: *BackendMachine, state_id: StateId) !void {
        if (cancel_requested.load(.acquire)) {
            stateFailed(self);
            return BackendError.Cancelled;
        }

        try self.stack.append(state_id);
        self.report(state_id);
    }

    // Releasing resources (stack memory) occupied by the state machine
    pub fn deinit(self: *BackendMachine) void {
        if (self.temp_path) |path| self.allocator.free(path);

        self.stack.deinit();
    }

    // Reports an installation progress event to the progress callback, if one is set
    pub fn report(self: *BackendMachine, event: StateId) void {
        const cb = self.request.on_progress orelse return;
        cb(event, CSlice.fromSlice(self.request.package_path), self.request.progress_ctx);
    }

    pub fn reportDetail(self: *BackendMachine, message: []const u8) void {
        const cb = self.request.on_progress orelse return;
        cb(.special_step, CSlice.fromSlice(message), self.request.progress_ctx);
    }

    // The entry and launch point of the machine, responsible for returning the correct result
    pub fn run(request: PrepareRequest, allocator: std.mem.Allocator) !PrepareResult {
        cancel_requested.store(false, .release);

        const sigaction = std.posix.Sigaction{ .handler = .{ .handler = backendSignalHandler }, .mask = std.posix.empty_sigset, .flags = 0 };
        std.posix.sigaction(std.posix.SIG.INT, &sigaction, null) catch {};
        std.posix.sigaction(std.posix.SIG.TERM, &sigaction, null) catch {};

        var machine = BackendMachine{
            .request = request,
            .stack = std.ArrayList(StateId).init(allocator),
            .allocator = allocator,
            .meta = null,
        };
        defer machine.deinit();
        try states.stateVerifying(&machine);

        const temp_path = machine.temp_path orelse return BackendError.TempDirFailed;
        machine.temp_path = null;

        return PrepareResult{
            .meta = machine.meta orelse return BackendError.InvalidPackage,
            .temp_path = temp_path,
        };
    }
};

// ── FFI ───────────────────────────────────────────────────────────────────────
// A helper structure for passing data slices via C FFI
const CSlice = extern struct {
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

// A C-compatible representation of package metadata for export to other languages
const CPackageMeta = extern struct {
    struct_size: usize = @sizeOf(CPackageMeta),

    name: CSlice,
    version: CSlice,
    arch: CSlice,
    author: CSlice,
    description: CSlice,
    license: CSlice,
    url: CSlice,
    packager: CSlice,
    checksum: CSlice,
    size: u32,
    _padding: u32 = 0,
    installed_at: i64,
};

// C-compatible request parameter structure for use in FFI
const CPrepareRequest = extern struct {
    struct_size: usize = @sizeOf(CPrepareRequest),

    package_path: CSlice,
    temp_dir: CSlice,
    checksum: CSlice,

    on_progress: ?CBackendProgressFn = null,
    progress_ctx: ?*anyopaque = null,

    pub fn validate(req: CPrepareRequest) !void {
        if (req.struct_size != @sizeOf(CPrepareRequest)) return error.AbiMismatch;

        if (req.package_path.isEmpty()) return error.InvalidEntry;
        if (req.temp_dir.isEmpty()) return error.InvalidEntry;
        if (req.checksum.isEmpty()) return error.InvalidEntry;
    }
};

pub const PrepareResult = struct {
    meta: PackageMeta,
    temp_path: [:0]const u8,
};

pub const BackendProgressFn = *const fn (
    event: StateId,
    package_name: CSlice,
    ctx: ?*anyopaque,
) callconv(.C) void;

pub const CBackendProgressFn = *const fn (
    event: StateId,
    package_name: CSlice,
    ctx: ?*anyopaque,
) callconv(.C) void;

// The main allocator for the entire library
var gpa = std.heap.GeneralPurposeAllocator(.{}){};

// ── FFI экспорты ──────────────────────────────────────────────────────────────
// An exported C function (FFI) for initiating the preparation process from external code
pub export fn upac_backend_prepare(request_c: *const CPrepareRequest, out_meta: *?*anyopaque, out_temp_path: *CSlice) callconv(.C) i32 {
    request_c.validate() catch |err| return @intFromEnum(fromError(err));

    const zig_request = PrepareRequest{
        .package_path = request_c.package_path.toSlice(),
        .temp_dir = request_c.temp_dir.toSlice(),
        .checksum = request_c.checksum.toSlice(),
        .on_progress = request_c.on_progress,
        .progress_ctx = request_c.progress_ctx,
    };

    const result = BackendMachine.run(zig_request, gpa.allocator()) catch |err| return @intFromEnum(fromError(err));
    const out_meta_ptr = gpa.allocator().create(CPackageMeta) catch return @intFromEnum(BackendErrorCode.alloc_failed);

    out_meta_ptr.* = CPackageMeta{
        .struct_size = @sizeOf(CPackageMeta),

        .name = dupeToCSlice(gpa.allocator(), result.meta.name) catch return @intFromEnum(fromError(BackendError.AllocZFailed)),
        .version = dupeToCSlice(gpa.allocator(), result.meta.version) catch return @intFromEnum(fromError(BackendError.AllocZFailed)),
        .size = @intCast(result.meta.size),
        .arch = dupeToCSlice(gpa.allocator(), result.meta.arch) catch return @intFromEnum(fromError(BackendError.AllocZFailed)),
        .author = dupeToCSlice(gpa.allocator(), result.meta.author) catch return @intFromEnum(fromError(BackendError.AllocZFailed)),
        .description = dupeToCSlice(gpa.allocator(), result.meta.description) catch return @intFromEnum(fromError(BackendError.AllocZFailed)),
        .license = dupeToCSlice(gpa.allocator(), result.meta.license) catch return @intFromEnum(fromError(BackendError.AllocZFailed)),
        .url = dupeToCSlice(gpa.allocator(), result.meta.url) catch return @intFromEnum(fromError(BackendError.AllocZFailed)),
        .packager = dupeToCSlice(gpa.allocator(), result.meta.packager) catch return @intFromEnum(fromError(BackendError.AllocZFailed)),
        .installed_at = result.meta.installed_at,
        .checksum = dupeToCSlice(gpa.allocator(), result.meta.checksum) catch return @intFromEnum(fromError(BackendError.AllocZFailed)),
    };

    out_meta.* = out_meta_ptr;
    out_temp_path.* = dupeToCSlice(gpa.allocator(), result.temp_path) catch return @intFromEnum(fromError(BackendError.AllocZFailed));

    return @intFromEnum(BackendErrorCode.ok);
}

fn on_backend_progress(event: StateId, detail_c: CSlice, ctx: ?*anyopaque) callconv(.C) void {
    if (ctx != null) {
        return;
    }
    _ = event;
    _ = detail_c;
}

fn dupeToCSlice(allocator: std.mem.Allocator, slice: []const u8) BackendError!CSlice {
    const dupe_slice = allocator.dupe(u8, slice) catch return BackendError.AllocZFailed;
    return CSlice.fromSlice(dupe_slice);
}

pub export fn upac_backend_cleanup(path_c: CSlice) callconv(.C) void {
    const path = path_c.toSlice();

    std.fs.deleteTreeAbsolute(path) catch {};
    gpa.allocator().free(path);
}

// A function for safely clearing metadata memory allocated on the Zig side
pub export fn upac_backend_meta_free(package_meta_c: *CPackageMeta) callconv(.C) void {
    gpa.allocator().free(package_meta_c.name.toSlice());
    gpa.allocator().free(package_meta_c.version.toSlice());
    gpa.allocator().free(package_meta_c.arch.toSlice());
    gpa.allocator().free(package_meta_c.author.toSlice());
    gpa.allocator().free(package_meta_c.description.toSlice());
    gpa.allocator().free(package_meta_c.license.toSlice());
    gpa.allocator().free(package_meta_c.packager.toSlice());
    gpa.allocator().free(package_meta_c.url.toSlice());
    gpa.allocator().free(package_meta_c.checksum.toSlice());

    gpa.allocator().destroy(package_meta_c);
}

pub export fn upac_backend_meta_get_name(meta: *const CPackageMeta) callconv(.C) CSlice {
    return meta.name;
}

pub export fn upac_backend_meta_get_version(meta: *const CPackageMeta) callconv(.C) CSlice {
    return meta.version;
}

pub const BackendErrorCode = enum(i32) {
    ok = 0,
    checksum_mismatch = 1,
    extraction_failed = 2,
    metadata_not_found = 3,
    invalid_package = 4,
    archive_open_failed = 5,
    archive_read_failed = 6,
    archive_extract_failed = 7,
    temp_dir_failed = 8,
    alloc_failed = 9,
    cancelled = 10,
    read_failed = 11,
    invalid_entry = 12,
    abi_mismatch = 13,
    unexpected = 99,
};

pub fn fromError(err: anyerror) BackendErrorCode {
    return switch (err) {
        BackendError.ChecksumMismatch => .checksum_mismatch,
        BackendError.ExtractionFailed => .extraction_failed,
        BackendError.MetadataNotFound => .metadata_not_found,
        BackendError.InvalidPackage => .invalid_package,
        BackendError.ArchiveOpenFailed => .archive_open_failed,
        BackendError.ArchiveReadFailed => .archive_read_failed,
        BackendError.ArchiveExtractFailed => .archive_extract_failed,
        BackendError.TempDirFailed => .temp_dir_failed,
        BackendError.AllocZFailed, BackendError.OutOfMemory => .alloc_failed,
        BackendError.Cancelled => .cancelled,
        BackendError.ReadFailed => .read_failed,
        error.InvalidEntry => .invalid_entry,
        error.AbiMismatch => .abi_mismatch,
        else => .unexpected,
    };
}
