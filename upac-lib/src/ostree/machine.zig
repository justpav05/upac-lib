const std = @import("std");

const ostree = @import("ostree.zig");
const OstreeCommitRequest = ostree.OstreeCommitRequest;

const c_librarys = @cImport({
    @cInclude("ostree.h");
    @cInclude("glib.h");
    @cInclude("gio/gio.h");
});

// ── Внутренние типы FSM ───────────────────────────────────────────────────────
pub const StateId = enum {
    opening_repo,
    building_message,
    committing,
    done,
    failed,
};

pub const CommitMachine = struct {
    request: OstreeCommitRequest,
    stack: std.ArrayList(StateId),
    retries: u8,
    max_retries: u8,
    allocator: std.mem.Allocator,
    repo: ?*c_librarys.OstreeRepo,
    subject: ?[]u8,
    body: ?[]u8,

    pub fn enter(self: *CommitMachine, id: StateId) !void {
        try self.stack.append(id);
        std.debug.print("[ostree → {s}]\n", .{@tagName(id)});
    }

    pub fn exhausted(self: *CommitMachine) bool {
        return self.retries >= self.max_retries;
    }

    pub fn deinit(self: *CommitMachine) void {
        self.stack.deinit();
        if (self.subject) |string| self.allocator.free(string);
        if (self.body) |string| self.allocator.free(string);
        if (self.repo) |repo| c_librarys.g_object_unref(repo);
    }
};
