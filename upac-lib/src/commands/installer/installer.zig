// ── Imports ─────────────────────────────────────────────────────────────────────
const data = @import("upac-data");

const CSlice = ffi.CSlice;

const InstallStateId = ffi.InstallStateId;
const InstallProgressFn = ffi.InstallProgressFn;

const Package = ffi.Package;
const PackageMeta = ffi.PackageMeta;

const file = @import("upac-file");
const c_libs = file.c_libs;

const states = @import("states.zig");
const stateFailed = states.stateFailed;

// ── Public imports ─────────────────────────────────────────────────────────────────────
pub const std = @import("std");
pub const ffi = @import("upac-ffi");

// ── Imports symbols ─────────────────────────────────────────────────────────────────────
pub usingnamespace @import("symbols.zig");

// ── Errors ────────────────────────────────────────────────────────────────────
//
pub const InstallerError = error{
    // Special errors
    AlreadyInstalled,
    PackageNotFound,
    NotEnoughSpace,
    CheckSpaceFailed,
    WriteDatabaseFailed,
    CollectFileChecksumsFailed,
    MakeFailed,
    // Global errors
    PathNotFound,
    RepoOpenFailed,
    RepoTransactionFailed,
    CheckoutFailed,
    AllocZFailed,
    OutOfMemory,
    Cancelled,
    MaxRetriesExceeded,
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
    prefix_directory: []const u8,

    on_progress: ?InstallProgressFn = null,
    progress_ctx: ?*anyopaque = null,

    max_retries: u8 = 0,
};

// ── InstallerMachine ──────────────────────────────────────────────────────────
// The main structure of a finite-state machine, with information persistence between states
pub const InstallerMachine = struct {
    data: InstallData,
    current_package_index: usize = 0,
    retries: u8,

    repo: ?*c_libs.OstreeRepo,
    mtree: ?*c_libs.OstreeMutableTree,

    staging_path: ?[:0]const u8 = null,
    commit_checksum: ?[*:0]u8 = null,
    previous_commit_checksum: ?[*:0]u8 = null,

    branch_c: ?[*:0]const u8 = null,

    stack: std.ArrayList(InstallStateId),
    cancellable: ?*c_libs.GCancellable = null,
    gerror: ?*c_libs.GError = null,
    signal_loop: ?*c_libs.GMainLoop = null,
    signal_thread: ?std.Thread = null,
    allocator: std.mem.Allocator,

    // Registers a transition to a new state, saving it to the stack. This allows for the reconstruction of the sequence of actions during debugging
    pub fn enter(self: *InstallerMachine, state_id: InstallStateId) !void {
        if (self.cancellable) |cancellable| {
            if (c_libs.g_cancellable_is_cancelled(cancellable) != 0) {
                stateFailed(self);
                return InstallerError.Cancelled;
            }
        }
        try self.stack.append(state_id);
        self.report(state_id);
    }

    // Resets the attempt counter before starting a new operation
    pub fn resetRetries(self: *InstallerMachine) void {
        self.retries = 0;
    }

    // Checks whether the retry limit for the current step has been exceeded. If the limit is exhausted, the installation is interrupted
    pub fn exhausted(self: *InstallerMachine) bool {
        return self.retries > self.data.max_retries;
    }

    pub fn retry(self: *InstallerMachine, comptime state_fn: anytype) InstallerError!void {
        if (self.cancellable) |cancellable| {
            if (c_libs.g_cancellable_is_cancelled(cancellable) != 0) {
                stateFailed(self);
                return InstallerError.Cancelled;
            }
        }

        if (self.exhausted()) {
            stateFailed(self);
            return InstallerError.MaxRetriesExceeded;
        }

        if (self.gerror) |err| {
            c_libs.g_error_free(err);
            self.gerror = null;
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

    // Correct memory deallocation function
    pub fn deinit(self: *InstallerMachine) void {
        if (self.mtree) |mtree| c_libs.g_object_unref(mtree);
        if (self.repo) |repo| c_libs.g_object_unref(repo);

        if (self.staging_path) |ptr| self.allocator.free(ptr);
        if (self.commit_checksum) |ptr| c_libs.g_free(@ptrCast(ptr));
        if (self.previous_commit_checksum) |ptr| c_libs.g_free(@ptrCast(ptr));

        if (self.branch_c) |ptr| self.allocator.free(std.mem.span(ptr));
        if (self.gerror) |ptr| c_libs.g_error_free(@ptrCast(ptr));
        if (self.cancellable) |cancellable| c_libs.g_object_unref(cancellable);

        if (self.signal_loop) |loop| {
            c_libs.g_main_loop_quit(loop);
        }
        if (self.signal_thread) |tread| {
            tread.join();
            self.signal_thread = null;
        }
        if (self.signal_loop) |loop| {
            c_libs.g_main_loop_unref(loop);
            self.signal_loop = null;
        }

        self.stack.deinit();
    }

    // Reports an installation progress event to the progress callback, if one is set
    pub fn report(self: *InstallerMachine, event: InstallStateId) void {
        const cb = self.data.on_progress orelse return;
        const name = if (self.current_package_index < self.data.packages.len)
            self.data.packages[self.current_package_index].package.meta.name
        else
            "";
        cb(event, CSlice.fromSlice(name), self.data.progress_ctx);
    }

    // Initializes the machine, creates the state stack, and launches the first stage—verification
    pub fn run(install_data: InstallData, allocator: std.mem.Allocator) InstallerError!void {
        const sigint_src = c_libs.g_unix_signal_source_new(std.posix.SIG.INT);
        const sigterm_src = c_libs.g_unix_signal_source_new(std.posix.SIG.TERM);

        const signal_ctx = c_libs.g_main_context_new();
        defer c_libs.g_main_context_unref(signal_ctx);

        var machine = InstallerMachine{
            .data = install_data,
            .current_package_index = 0,
            .retries = 0,

            .repo = null,
            .mtree = null,

            .stack = std.ArrayList(InstallStateId).init(allocator),
            .cancellable = c_libs.g_cancellable_new() orelse return InstallerError.OutOfMemory,
            .allocator = allocator,
        };
        defer machine.deinit();

        c_libs.g_source_set_callback(sigint_src, @ptrCast(&onCancelSignal), machine.cancellable, null);
        _ = c_libs.g_source_attach(sigint_src, signal_ctx);
        c_libs.g_source_unref(sigint_src);

        c_libs.g_source_set_callback(sigterm_src, @ptrCast(&onCancelSignal), machine.cancellable, null);
        _ = c_libs.g_source_attach(sigterm_src, signal_ctx);
        c_libs.g_source_unref(sigterm_src);

        machine.signal_loop = c_libs.g_main_loop_new(signal_ctx, 0);
        machine.signal_thread = std.Thread.spawn(.{}, signalLoopThread, .{machine.signal_loop.?}) catch null;

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
                if (c_libs.ostree_checksum_file(gfile, c_libs.OSTREE_OBJECT_TYPE_FILE, &raw_checksum_bin, machine.cancellable, &gerror) == 0) return InstallerError.CollectFileChecksumsFailed;
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

fn onCancelSignal(user_data: c_libs.gpointer) callconv(.C) c_libs.gboolean {
    const cancellable = @as(*c_libs.GCancellable, @ptrCast(@alignCast(user_data)));
    c_libs.g_cancellable_cancel(cancellable);
    return c_libs.G_SOURCE_REMOVE;
}

fn signalLoopThread(loop: *c_libs.GMainLoop) void {
    c_libs.g_main_loop_run(loop);
}
