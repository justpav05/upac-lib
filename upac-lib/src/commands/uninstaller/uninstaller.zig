// ── Imports ─────────────────────────────────────────────────────────────────────
const data = @import("upac-data");

const CSlice = ffi.CSlice;

const UninstallStateId = ffi.UninstallStateId;
const UninstallProgressFn = ffi.UninstallProgressFn;

const file = @import("upac-file");
const c_libs = file.c_libs;

const states = @import("states.zig");
const stateFailed = states.stateFailed;

// ── Public imports ─────────────────────────────────────────────────────────────────────
pub const std = @import("std");
pub const ffi = @import("upac-ffi");

// ── Imports symbols ─────────────────────────────────────────────────────────────────────
pub usingnamespace @import("symbols.zig");

// ── Errors ─────────────────────────────────────────────────────────────────────
// Errors specific to the removal process
pub const UninstallerError = error{
    // Specific errors
    PackageNotFound,
    FileNotFound,
    FileMapCorrupted,
    StagingNotCleaned,
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

// ── UninstallerFSM data ─────────────────────────────────────────────────────────────────────
// Set of input parameters: package name, paths to the repository and database, as well as the target branch for the commit
pub const UninstallData = struct {
    package_names: []const []const u8,

    repo_path: []const u8,
    root_path: []const u8,
    db_path: []const u8,

    branch: []const u8,
    prefix_directory: []const u8,

    on_progress: ?UninstallProgressFn = null,
    progress_ctx: ?*anyopaque = null,

    max_retries: u8 = 0,
};

// ── UninstallerFSM ─────────────────────────────────────────────────────────────────────
// Uninstaller state container for fsm data between states
pub const UninstallerMachine = struct {
    data: UninstallData,
    current_package_index: usize,
    retries: u8,

    repo: ?*c_libs.OstreeRepo,
    mtree: ?*c_libs.OstreeMutableTree,

    staging_path: ?[:0]const u8 = null,
    commit_checksum: ?[*:0]u8 = null,
    previous_commit_checksum: ?[*:0]u8 = null,

    branch_c: ?[*:0]const u8 = null,

    package_file_map: ?data.FileMap,
    package_checksum: ?[]const u8,

    stack: std.ArrayList(UninstallStateId),
    cancellable: ?*c_libs.GCancellable = null,
    gerror: ?*c_libs.GError = null,
    signal_loop: ?*c_libs.GMainLoop = null,
    signal_thread: ?std.Thread = null,
    allocator: std.mem.Allocator,

    // Registers a transition to a new state, adding it to the stack for progress tracking and debugging
    pub fn enter(self: *UninstallerMachine, state_id: UninstallStateId) !void {
        if (self.cancellable) |cancellable| {
            if (c_libs.g_cancellable_is_cancelled(cancellable) != 0) {
                stateFailed(self);
                return UninstallerError.Cancelled;
            }
        }

        try self.stack.append(state_id);
        self.report(state_id);
    }

    // Resets the retry counter before executing a new operation
    pub fn resetRetries(self: *UninstallerMachine) void {
        self.retries = 0;
    }

    // Checks whether the attempt limit for the current uninstallation step has been exhausted
    pub fn exhausted(self: *UninstallerMachine) bool {
        return self.retries > self.data.max_retries;
    }

    pub fn retry(self: *UninstallerMachine, comptime state_fn: anytype) UninstallerError!void {
        if (self.cancellable) |cancellable| {
            if (c_libs.g_cancellable_is_cancelled(cancellable) != 0) {
                stateFailed(self);
                return UninstallerError.Cancelled;
            }
        }

        if (self.exhausted()) {
            stateFailed(self);
            return UninstallerError.MaxRetriesExceeded;
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
    pub fn resetTransaction(self: *UninstallerMachine) UninstallerError!void {
        var gerror: ?*c_libs.GError = null;
        defer if (gerror) |err| c_libs.g_error_free(err);

        _ = c_libs.ostree_repo_abort_transaction(self.repo.?, null, null);
        if (c_libs.ostree_repo_prepare_transaction(self.repo.?, null, null, &gerror) == 0) {
            stateFailed(self);
            return UninstallerError.RepoOpenFailed;
        }
    }

    // Releases all resources: native Zig memory, the file hash map, and OSTree system C objects
    pub fn deinit(self: *UninstallerMachine) void {
        if (self.staging_path) |path| self.allocator.free(path);
        if (self.commit_checksum) |checksum| c_libs.g_free(@ptrCast(checksum));
        if (self.previous_commit_checksum) |checksum| c_libs.g_free(@ptrCast(checksum));

        if (self.mtree) |mtree| c_libs.g_object_unref(mtree);
        if (self.repo) |repo| c_libs.g_object_unref(repo);

        if (self.branch_c) |branch| self.allocator.free(std.mem.span(branch));

        if (self.package_file_map) |*map| data.freeFileMap(@constCast(map), self.allocator);
        if (self.package_checksum) |checksum| self.allocator.free(checksum);

        if (self.gerror) |err| c_libs.g_error_free(err);
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

    // Reports an uninstallation progress event to the progress callback, if one is set
    pub fn report(self: *UninstallerMachine, event: UninstallStateId) void {
        const cb = self.data.on_progress orelse return;
        const name = if (self.current_package_index < self.data.package_names.len)
            self.data.package_names[self.current_package_index]
        else
            "";
        cb(event, CSlice.fromSlice(name), self.data.progress_ctx);
    }

    // Entry point: initializes the uninstallation engine and launches the package removal process
    pub fn run(uninstall_data: UninstallData, allocator: std.mem.Allocator) !void {
        const sigint_src = c_libs.g_unix_signal_source_new(std.posix.SIG.INT);
        const sigterm_src = c_libs.g_unix_signal_source_new(std.posix.SIG.TERM);

        const signal_ctx = c_libs.g_main_context_new();
        defer c_libs.g_main_context_unref(signal_ctx);

        var machine = UninstallerMachine{
            .data = uninstall_data,
            .current_package_index = 0,
            .retries = 0,

            .repo = null,
            .mtree = null,

            .package_file_map = null,
            .package_checksum = null,

            .stack = std.ArrayList(UninstallStateId).init(allocator),
            .cancellable = c_libs.g_cancellable_new() orelse return UninstallerError.OutOfMemory,
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

// ── Helpers functions ─────────────────────────────────────────────────────────────────────
// Removes the file entry from the file table of the corresponding directory
pub fn removeFromMtree(repo: *c_libs.OstreeRepo, root_mtree: *c_libs.OstreeMutableTree, relative_path: []const u8, allocator: std.mem.Allocator) !void {
    var gerror: ?*c_libs.GError = null;
    defer if (gerror) |err| c_libs.g_error_free(@ptrCast(err));

    var path_components = std.ArrayList([]const u8).init(allocator);
    defer path_components.deinit();

    var path_components_iter = std.mem.splitScalar(u8, relative_path, '/');
    while (path_components_iter.next()) |path_part| {
        if (path_part.len > 0) try path_components.append(path_part);
    }
    if (path_components.items.len == 0) return;

    var current_subtree = root_mtree;
    for (path_components.items[0 .. path_components.items.len - 1]) |directory_component| {
        const contents_checksum = c_libs.ostree_mutable_tree_get_contents_checksum(current_subtree);
        const metadata_checksum = c_libs.ostree_mutable_tree_get_metadata_checksum(current_subtree);
        if (contents_checksum != null and metadata_checksum != null) {
            _ = c_libs.ostree_mutable_tree_fill_empty_from_dirtree(current_subtree, repo, contents_checksum, metadata_checksum);
        }

        const directory_component_c = try allocator.dupeZ(u8, directory_component);
        defer allocator.free(directory_component_c);

        var out_file_checksum: [*c]u8 = null;
        var out_subdir: ?*c_libs.OstreeMutableTree = null;

        if (c_libs.ostree_mutable_tree_lookup(current_subtree, directory_component_c.ptr, &out_file_checksum, &out_subdir, &gerror) == 0) return UninstallerError.FileNotFound;

        if (out_subdir == null) return UninstallerError.FileNotFound;
        current_subtree = out_subdir.?;
    }

    const contents_checksum = c_libs.ostree_mutable_tree_get_contents_checksum(current_subtree);
    const metadata_checksum = c_libs.ostree_mutable_tree_get_metadata_checksum(current_subtree);
    if (contents_checksum != null and metadata_checksum != null) {
        _ = c_libs.ostree_mutable_tree_fill_empty_from_dirtree(current_subtree, repo, contents_checksum, metadata_checksum);
    }

    const file_name_c = try allocator.dupeZ(u8, path_components.items[path_components.items.len - 1]);
    defer allocator.free(file_name_c);

    if (c_libs.ostree_mutable_tree_remove(current_subtree, file_name_c.ptr, 0, &gerror) == 0) return UninstallerError.FileNotFound;
}

fn onCancelSignal(user_data: c_libs.gpointer) callconv(.C) c_libs.gboolean {
    const cancellable = @as(*c_libs.GCancellable, @ptrCast(@alignCast(user_data)));
    c_libs.g_cancellable_cancel(cancellable);
    return c_libs.G_SOURCE_REMOVE;
}

fn signalLoopThread(loop: *c_libs.GMainLoop) void {
    c_libs.g_main_loop_run(loop);
}
