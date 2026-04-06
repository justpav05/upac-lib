const std = @import("std");

pub const c_libs = @cImport({
    @cInclude("ostree.h");
    @cInclude("glib.h");
    @cInclude("gio/gio.h");
    @cInclude("fcntl.h");
});

const states = @import("states.zig");

// ── Errors ────────────────────────────────────────────────────────────────────
pub const FileFSMError = error{
    FileNotFound,
    ChecksumFailed,
    FileAlreadyExists,
    RepoWriteFailed,
    MtreeInsertFailed,
    MaxRetriesExceeded,
};

// ── FileFSMStateId ────────────────────────────────────────────────────────────
pub const FileFSMStateId = enum {
    start,

    checksum,
    write_object,
    insert_mtree,

    done,
    failed,
};

// ── FileFSMEnterData ──────────────────────────────────────────────────────────
pub const FileFSMEnterData = struct {
    temp_path: [:0]const u8,
    relative_path: []const u8,

    repo: *c_libs.OstreeRepo,
    mtree: *c_libs.OstreeMutableTree,
};

// ── FileFSM ───────────────────────────────────────────────────────────────────
pub const FileFSM = struct {
    retries: u8,
    max_retries: u8,

    data: FileFSMEnterData,

    file_checksum: ?[]const u8,

    stack: std.ArrayList(FileFSMStateId),
    allocator: std.mem.Allocator,

    pub fn enter(self: *FileFSM, state_id: FileFSMStateId) !void {
        try self.stack.append(state_id);
    }

    pub fn resetRetries(self: *FileFSM) void {
        self.retries = 0;
    }

    pub fn exhausted(self: *FileFSM) bool {
        return self.retries >= self.max_retries;
    }

    pub fn deinit(self: *FileFSM) void {
        if (self.file_checksum) |cs| self.allocator.free(cs);
        self.stack.deinit();
    }

    pub fn run(data: FileFSMEnterData, max_retries: u8, allocator: std.mem.Allocator) ![]const u8 {
        var machine = FileFSM{
            .retries = 0,
            .max_retries = max_retries,

            .data = data,

            .file_checksum = null,

            .stack = std.ArrayList(FileFSMStateId).init(allocator),
            .allocator = allocator,
        };
        defer machine.stack.deinit();
        errdefer if (machine.file_checksum) |checksum| allocator.free(checksum);

        try states.stateStart(&machine);

        return machine.file_checksum orelse FileFSMError.ChecksumFailed;
    }
};
