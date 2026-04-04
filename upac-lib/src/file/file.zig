const std = @import("std");
pub const c_libs = @cImport({
    @cInclude("ostree.h");
    @cInclude("glib.h");
    @cInclude("gio/gio.h");
    @cInclude("fcntl.h");
});

const states = @import("states.zig");

// ── Errors ───────────────────────────────────────────────────────────────────
pub const FileFSMError = error{
    FileNotFound,
    ChecksumComputeFailed,
    ChecksumMismatch,
    RepoWriteFailed,
    RelativePathMismatch,
    MtreeEnsureDirFailed,
    MaxRetriesExceeded,
};

// ── FileFSMStateId ───────────────────────────────────────────────────────────
pub const FileFSMStateId = enum {
    start,

    validation,
    copying,

    get_relative_path,
    add_to_mtree,

    done,
    failed,
};

// ── FileFSMEnterData ─────────────────────────────────────────────────────────
pub const FileFSMEnterData = struct {
    temp_path: [:0]const u8,
    relative_path: []const u8,

    repo: *c_libs.OstreeRepo,
    mtree: *c_libs.OstreeMutableTree,
};

// ── FileFSM ──────────────────────────────────────────────────────────────────
pub const FileFSM = struct {
    retries: u8,
    max_retries: u8,

    temp_file_checksum: ?[]const u8,
    ostree_file_checksum: ?[]const u8,

    data: FileFSMEnterData,

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
        if (self.temp_file_checksum) |checksum| self.allocator.free(checksum);
        if (self.ostree_file_checksum) |checksum| self.allocator.free(checksum);
        self.stack.deinit();
    }

    pub fn run(data: FileFSMEnterData, max_retries: u8, allocator: std.mem.Allocator) !void {
        var machine = FileFSM{
            .retries = 0,
            .max_retries = max_retries,

            .data = data,

            .temp_file_checksum = null,
            .ostree_file_checksum = null,

            .stack = std.ArrayList(FileFSMStateId).init(allocator),

            .allocator = allocator,
        };
        defer machine.deinit();

        try states.stateStart(&machine);
    }
};
