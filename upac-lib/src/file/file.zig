// ── Imports ─────────────────────────────────────────────────────────────────────
const std = @import("std");

pub const c_libs = @cImport({
    @cInclude("ostree.h");
    @cInclude("glib.h");
    @cInclude("gio/gio.h");
    @cInclude("fcntl.h");
});

const states = @import("states.zig");

// ── Errors ────────────────────────────────────────────────────────────────────
// A list of errors encountered during file processing (checksum error, attempt limit exceeded, repository write error)
pub const FileFSMError = error{
    FileNotFound,
    ChecksumFailed,
    FileAlreadyExists,
    RepoWriteFailed,
    MtreeInsertFailed,
    MaxRetriesExceeded,
};

// ── FileFSMStateId ────────────────────────────────────────────────────────────
// A list of all possible states of the automaton: from hash computation to object writing and termination
pub const FileFSMStateId = enum {
    start,

    checksum,
    write_object,
    insert_mtree,

    done,
    failed,
};

// ── FileFSMEnterData ──────────────────────────────────────────────────────────
// A container holding input data for the state machine: a temporary file path, a target path within the repository, and pointers to OSTree objects (the repository and the mutable tree)
pub const FileFSMEnterData = struct {
    temp_path: [:0]const u8,
    relative_path: []const u8,

    repo: *c_libs.OstreeRepo,
    mtree: *c_libs.OstreeMutableTree,
};

// ── FileFSM ───────────────────────────────────────────────────────────────────
// The main structure of the automaton, which tracks the number of retries, stores the calculated file checksum and the state stack
pub const FileFSM = struct {
    retries: u8,
    max_retries: u8,

    data: FileFSMEnterData,

    file_checksum: ?[]const u8,

    stack: std.ArrayList(FileFSMStateId),
    allocator: std.mem.Allocator,

    // Registers a transition to a new state by adding its identifier to the stack
    pub fn enter(self: *FileFSM, state_id: FileFSMStateId) !void {
        try self.stack.append(state_id);
    }

    // Resets the attempt counter (useful when transitioning between stages where transient failures may occur)
    pub fn resetRetries(self: *FileFSM) void {
        self.retries = 0;
    }

    // Checks whether the limit on attempts for the current operation has been exhausted
    pub fn exhausted(self: *FileFSM) bool {
        return self.retries >= self.max_retries;
    }

    // Frees the memory occupied by the checksum string and the state stack
    pub fn deinit(self: *FileFSM) void {
        if (self.file_checksum) |cs| self.allocator.free(cs);
        self.stack.deinit();
    }

    // A static function for initializing and starting the automaton's execution loop. It returns the final checksum of the processed file
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
