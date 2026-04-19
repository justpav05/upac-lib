// ── Imports ─────────────────────────────────────────────────────────────────────
const std = @import("std");

const data = @import("upac-data");

const CSlice = ffi.CSlice;

const Package = ffi.Package;
const PackageMeta = ffi.PackageMeta;

const InstallProgressFn = ffi.InstallProgressFn;
const InstallProgressEvent = ffi.InstallProgressEvent;

const file = @import("upac-file");
const c_libs = file.c_libs;

const states = @import("states.zig");
const stateFailed = states.stateFailed;

// ── Public imports ─────────────────────────────────────────────────────────────────────
pub const ffi = @import("upac-ffi");

// ── Imports symbols ─────────────────────────────────────────────────────────────────────
pub usingnamespace @import("symbols.zig");

// ── Errors ────────────────────────────────────────────────────────────────────
//
pub const InstallerError = error{
    // Package errors
    AlreadyInstalled,
    PackagePathNotFound,
    // Space errors
    NotEnoughSpace,
    CheckSpaceFailed,
    // Repo errors
    RepoPathNotFound,
    RepoOpenFailed,
    RepoTransactionFailed,
    // Database errors
    WriteDatabaseFailed,
    CollectFileChecksumsFailed,
    // Checkout errors
    CheckoutFailed,
    // Stateg errors
    AllocZFailed,
    MakeFailed,
    OutOfMemory,
    ErrorTreadError,
    // Retry errors
    Cancelled,
    MaxRetriesExceeded,
};

// ── StateId ───────────────────────────────────────────────────────────────────
// Listing of all stages of the installation's lifecycle
pub const StateId = enum {
    verifying,
    check_space,
    open_repo,
    check_installed,
    write_database,
    process_db_files,
    commit,
    checkout,

    done,
    failed,
};

pub const InstallEntry = struct {
    package: Package,
    temp_path: []const u8,
    checksum: []const u8,
};

// ── InstallData ───────────────────────────────────────────────────────────────
// A container structure holding all installation parameters: package metadata, paths to the repository and database, as well as retry limits
pub const InstallData = struct {
    packages: []const InstallEntry,

    repo_path: []const u8,
    root_path: []const u8,
    database_path: []const u8,

    branch: []const u8,

    on_progress: ?InstallProgressFn = null,
    progress_ctx: ?*anyopaque = null,

    max_retries: u8 = 0,
};

// ── InstallerMachine ──────────────────────────────────────────────────────────
// The main structure of a finite-state machine, with information persistence between states
pub const InstallerMachine = struct {
    data: InstallData,
    retries: u8,

    repo: ?*c_libs.OstreeRepo,
    mtree: ?*c_libs.OstreeMutableTree,
    commit_checksum: ?[*:0]u8 = null,
    previous_commit_checksum: ?[*:0]u8 = null,

    current_package_index: usize = 0,

    staging_path: ?[:0]const u8 = null,

    stack: std.ArrayList(StateId),
    cancellable: ?*c_libs.GCancellable = null,
    allocator: std.mem.Allocator,

    // Registers a transition to a new state, saving it to the stack. This allows for the reconstruction of the sequence of actions during debugging
    pub fn enter(self: *InstallerMachine, state_id: StateId) !void {
        if (self.cancellable) |cancellable| {
            if (c_libs.g_cancellable_is_cancelled(cancellable) != 0) {
                stateFailed(self);
                return InstallerError.Cancelled;
            }
        }

        try self.stack.append(state_id);

        self.report(switch (state_id) {
            .verifying => .verifying,
            .check_space => .check_space,
            .open_repo => .open_repo,
            .check_installed => .check_installed,
            .write_database => .write_database,
            .commit => .commit,
            .checkout => .checkout,

            .done => .done,
            .failed => .failed,
            else => return,
        });
    }

    // Resets the attempt counter before starting a new operation
    pub fn resetRetries(self: *InstallerMachine) void {
        self.retries = 0;
    }

    // Checks whether the retry limit for the current step has been exceeded. If the limit is exhausted, the installation is interrupted
    pub fn exhausted(self: *InstallerMachine) bool {
        return self.retries > self.data.max_retries;
    }

    // Correct memory deallocation function
    pub fn deinit(self: *InstallerMachine) void {
        if (self.mtree) |mtree| c_libs.g_object_unref(mtree);
        if (self.repo) |repo| c_libs.g_object_unref(repo);

        if (self.commit_checksum) |ptr| c_libs.g_free(@ptrCast(ptr));
        if (self.previous_commit_checksum) |ptr| c_libs.g_free(@ptrCast(ptr));

        if (self.staging_path) |ptr| self.allocator.free(ptr);

        if (self.cancellable) |cancellable| c_libs.g_object_unref(cancellable);
        self.stack.deinit();
    }

    pub fn retry(self: *InstallerMachine, comptime state_fn: anytype) InstallerError!void {
        if (self.exhausted()) {
            stateFailed(self);
            return InstallerError.MaxRetriesExceeded;
        }
        self.retries += 1;
        try self.resetTransaction();
        return state_fn(self);
    }

    // Resets the transaction by aborting any ongoing transaction and preparing a new one. If the transaction cannot be reset, returns an error
    pub fn resetTransaction(self: *InstallerMachine) InstallerError!void {
        var gerror: ?*c_libs.GError = null;
        defer if (gerror) |err| c_libs.g_error_free(err);

        _ = c_libs.ostree_repo_abort_transaction(self.repo.?, null, null);
        if (c_libs.ostree_repo_prepare_transaction(self.repo.?, null, null, &gerror) == 0) return InstallerError.RepoOpenFailed;
    }

    // Reports an installation progress event to the progress callback, if one is set
    pub fn report(self: *InstallerMachine, event: InstallProgressEvent) void {
        const cb = self.data.on_progress orelse return;
        const name = if (self.current_package_index < self.data.packages.len)
            self.data.packages[self.current_package_index].package.meta.name
        else
            "";
        cb(event, CSlice.fromSlice(name), self.data.progress_ctx);
    }

    // Initializes the machine, creates the state stack, and launches the first stage—verification
    pub fn run(install_data: InstallData, allocator: std.mem.Allocator) InstallerError!void {
        var set = std.os.linux.empty_sigset;
        std.os.linux.sigaddset(&set, std.os.linux.SIG.INT);
        std.os.linux.sigaddset(&set, std.os.linux.SIG.TERM);
        _ = std.os.linux.sigprocmask(std.os.linux.SIG.BLOCK, &set, null);

        const raw_sfd = std.os.linux.syscall4(.signalfd4, @as(usize, @bitCast(@as(isize, -1))), @intFromPtr(&set), @sizeOf(std.os.linux.sigset_t), 0);
        const raw_efd = std.os.linux.syscall2(.eventfd2, 0, 0);

        const sfd: i32 = @truncate(@as(isize, @bitCast(raw_sfd)));
        defer _ = std.os.linux.close(@intCast(sfd));

        const efd: i32 = @truncate(@as(isize, @bitCast(raw_efd)));
        defer _ = std.os.linux.close(@intCast(efd));

        var machine = InstallerMachine{
            .data = install_data,

            .retries = 0,

            .repo = null,
            .mtree = null,

            .current_package_index = 0,

            .stack = std.ArrayList(StateId).init(allocator),
            .cancellable = c_libs.g_cancellable_new(),
            .allocator = allocator,
        };
        defer machine.deinit();
        errdefer stateFailed(&machine);

        const args = .{ &machine, sfd, efd };
        const thread = std.Thread.spawn(.{}, signalMonitorThread, args) catch return InstallerError.ErrorTreadError;
        defer {
            const one: u64 = 1;
            _ = std.os.linux.syscall3(.write, @as(usize, @intCast(efd)), @intFromPtr(&one), @sizeOf(u64));
            thread.join();
        }

        try states.stateVerifying(&machine);
    }
};

// ── Helpers functions ───────────────────────────────────────────────────
// A recursive assistant. It traverses the directory structure, calculates checksums for all files, and populates the FileMap. It is precisely this data that is subsequently written to the `.files` file within the database
pub fn collectFileChecksums(machine: *InstallerMachine, dir_path: []const u8, prefix: []const u8, file_map: *data.FileMap) !void {
    var gerror: ?*c_libs.GError = null;
    defer if (gerror) |err| c_libs.g_error_free(err);

    var dir = try std.fs.openDirAbsolute(dir_path, .{ .iterate = true });
    defer dir.close();

    var dir_iter = dir.iterate();
    while (try dir_iter.next()) |entry| {
        const entry_path = try std.fs.path.join(machine.allocator, &.{ dir_path, entry.name });
        defer machine.allocator.free(entry_path);

        switch (entry.kind) {
            .directory => try collectFileChecksums(machine, entry_path, prefix, file_map),
            .file => {
                const entry_path_c = try machine.allocator.dupeZ(u8, entry_path);
                defer machine.allocator.free(entry_path_c);

                const gfile = c_libs.g_file_new_for_path(entry_path_c.ptr);
                defer c_libs.g_object_unref(@ptrCast(gfile));

                var raw_checksum_bin: ?[*:0]u8 = null;
                if (c_libs.ostree_checksum_file(gfile, c_libs.OSTREE_OBJECT_TYPE_FILE, &raw_checksum_bin, null, &gerror) == 0) return InstallerError.CollectFileChecksumsFailed;
                defer c_libs.g_free(@ptrCast(raw_checksum_bin));

                var hex_checksum_buf: [65]u8 = undefined;
                c_libs.ostree_checksum_inplace_from_bytes(raw_checksum_bin.?, &hex_checksum_buf);

                const relative = entry_path[prefix.len..];
                try file_map.put(
                    try machine.allocator.dupe(u8, relative),
                    try machine.allocator.dupe(u8, hex_checksum_buf[0..64]),
                );
            },
            else => {},
        }
    }
}

pub fn dirSize(allocator: std.mem.Allocator, path: []const u8) !u64 {
    var total_size: u64 = 0;
    var dir = try std.fs.openDirAbsolute(path, .{ .iterate = true });
    defer dir.close();

    var dir_iter = dir.iterate();
    while (try dir_iter.next()) |entry| {
        const entry_path = try std.fs.path.join(allocator, &.{ path, entry.name });
        defer allocator.free(entry_path);

        switch (entry.kind) {
            .file => {
                const s = try std.fs.cwd().statFile(entry_path);
                total_size += s.size;
            },
            .directory => total_size += try dirSize(allocator, entry_path),
            else => {},
        }
    }
    return total_size;
}

fn signalMonitorThread(machine: *InstallerMachine, sfd: i32, efd: i32) void {
    var fds = [2]std.os.linux.pollfd{
        .{ .fd = sfd, .events = std.os.linux.POLL.IN, .revents = 0 },
        .{ .fd = efd, .events = std.os.linux.POLL.IN, .revents = 0 },
    };

    _ = std.os.linux.syscall3(.poll, @intFromPtr(&fds), 2, @bitCast(@as(isize, -1)));

    if (fds[1].revents & std.os.linux.POLL.IN != 0) return;

    if (fds[0].revents & std.os.linux.POLL.IN != 0) {
        var info: std.os.linux.signalfd_siginfo = undefined;
        _ = std.os.linux.syscall3(.read, @as(usize, @intCast(sfd)), @intFromPtr(&info), @sizeOf(@TypeOf(info)));

        if (info.signo == std.os.linux.SIG.INT or info.signo == std.os.linux.SIG.TERM) {
            if (machine.cancellable) |cancellable| c_libs.g_cancellable_cancel(cancellable);
        }
    }
}
