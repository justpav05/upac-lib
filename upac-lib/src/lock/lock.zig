const std = @import("std");
const posix = std.posix;

// ── Types ─────────────────────────────────────────────────────────────────────
pub const LockKind = enum {
    shared,
    exclusive,
};

pub const LockError = error{
    WouldBlock,
    Unexpected,
};

// ── Lock ──────────────────────────────────────────────────────────────────────
pub const Lock = struct {
    file_descriptor: posix.fd_t,
    kind: LockKind,

    pub fn tryAcquire(file_descriptor: posix.fd_t, kind: LockKind) LockError!Lock {
        const lock_kind_c_int: c_int = switch (kind) {
            .shared => std.c.LOCK.SH | std.c.LOCK.NB,
            .exclusive => std.c.LOCK.EX | std.c.LOCK.NB,
        };

        const block_result = std.c.flock(file_descriptor, lock_kind_c_int);

        if (block_result != 0) {
            return switch (posix.errno(block_result)) {
                .AGAIN => LockError.WouldBlock,
                else => LockError.Unexpected,
            };
        }

        return Lock{ .file_descriptor = file_descriptor, .kind = kind };
    }

    pub fn isLocked(file_descriptor: posix.fd_t) LockError!bool {
        const block_result = std.c.flock(file_descriptor, std.c.LOCK.EX | std.c.LOCK.NB);
        if (block_result == 0) {
            _ = std.c.flock(file_descriptor, std.c.LOCK.UN);
            return false;
        }

        return switch (posix.errno(block_result)) {
            .WOULDBLOCK => true,
            else => LockError.Unexpected,
        };
    }

    pub fn release(self: *Lock) void {
        _ = std.c.flock(self.file_descriptor, std.c.LOCK.UN);
    }
};
