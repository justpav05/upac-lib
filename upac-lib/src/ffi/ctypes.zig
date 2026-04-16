// ── Imports ─────────────────────────────────────────────────────────────────────
const std = @import("std");

const types = @import("upac-types");
const InstallProgressEvent = types.InstallProgressEvent;
const UninstallProgressEvent = types.UninstallProgressEvent;

// A C-compatible slice analogue. It stores a pointer to the data and its length. It allows for easy conversion of data between Zig and an external interface
pub const CSlice = extern struct {
    ptr: [*]const u8,
    len: usize,

    // Converts a native Zig slice into a C-compatible CSlice struct, packaging the pointer and length
    pub fn fromSlice(slice: []const u8) CSlice {
        return .{ .ptr = slice.ptr, .len = slice.len };
    }

    // It performs the inverse operation—reconstructing a safe Zig slice from data received via a C interface—so that it can be manipulated using standard language constructs
    pub fn toSlice(self: CSlice) []const u8 {
        return self.ptr[0..self.len];
    }

    // A simple check to determine whether a passed string or data array is empty (i.e., has zero length)
    pub fn isEmpty(self: CSlice) bool {
        return self.len == 0;
    }
};

// A wrapper over pointers to arrays of structures used to pass dynamic lists across the C boundary
pub const CSliceArray = extern struct {
    ptr: [*]CSlice,
    len: usize,

    pub fn toSlice(self: CSliceArray) []CSlice {
        return self.ptr[0..self.len];
    }
};

pub const CPackageDiffKind = enum(u8) {
    added = 0,
    removed = 1,
    updated = 2,
};

pub const CPackageEntry = extern struct {
    meta: CPackageMeta,
    temp_path: CSlice,
    checksum: CSlice,
};

// A packet metadata structure adapted for transmission via C
pub const CPackageMeta = extern struct {
    name: CSlice,
    version: CSlice,
    author: CSlice,
    description: CSlice,
    license: CSlice,
    url: CSlice,
    installed_at: i64,
    checksum: CSlice,
};

pub const CPackageMetaArray = extern struct {
    ptr: [*]CPackageMeta,
    len: usize,

    pub fn toSlice(self: CPackageMetaArray) []CPackageMeta {
        return self.ptr[0..self.len];
    }
};

// Parameter sets for the сorresponding operation — Installation
pub const CInstallRequest = extern struct {
    packages: [*]const CPackageEntry,
    packages_len: usize,

    repo_path: CSlice,
    root_path: CSlice,
    db_path: CSlice,

    branch: CSlice,

    on_progress: ?CInstallProgressFn = null,
    progress_ctx: ?*anyopaque = null,

    max_retries: u8,
};

pub const InstallProgressFn = *const fn (
    event: InstallProgressEvent,
    package_name: CSlice,
    ctx: ?*anyopaque,
) callconv(.C) void;

pub const CInstallProgressFn = *const fn (
    event: u8,
    package_name: CSlice,
    ctx: ?*anyopaque,
) callconv(.C) void;

// // Parameter sets for the сorresponding operation — Uninstallation
pub const CUninstallRequest = extern struct {
    package_names: [*]const CSlice,
    package_names_len: usize,

    repo_path: CSlice,
    root_path: CSlice,
    db_path: CSlice,

    branch: CSlice,

    on_progress: ?CUninstallProgressFn = null,
    progress_ctx: ?*anyopaque = null,

    max_retries: u8,
};

pub const UninstallProgressFn = *const fn (
    event: UninstallProgressEvent,
    package_name: CSlice,
    ctx: ?*anyopaque,
) callconv(.C) void;

pub const CUninstallProgressFn = *const fn (
    event: u8,
    package_name: CSlice,
    ctx: ?*anyopaque,
) callconv(.C) void;

// Enumeration of file system change types (added, deleted, modified)
pub const CDiffKind = enum(u8) {
    added = 0,
    removed = 1,
    modified = 2,
};

//
pub const CDiffEntry = extern struct {
    path: CSlice,
    kind: CDiffKind,
};

// A wrapper over pointers to arrays of structures used to pass dynamic lists across the C boundary
pub const CDiffArray = extern struct {
    ptr: [*]CDiffEntry,
    len: usize,

    pub fn toSlice(self: CDiffArray) []CDiffEntry {
        return self.ptr[0..self.len];
    }
};

pub const CPackageDiffEntry = extern struct {
    name: CSlice,
    kind: CPackageDiffKind,
};

pub const CPackageDiffArray = extern struct {
    ptr: [*]CPackageDiffEntry,
    len: usize,

    pub fn toSlice(self: CPackageDiffArray) []CPackageDiffEntry {
        return self.ptr[0..self.len];
    }
};

pub const CAttributedDiffEntry = extern struct {
    path: CSlice,
    kind: CDiffKind,
    package_name: CSlice,
};

pub const CAttributedDiffArray = extern struct {
    ptr: [*]CAttributedDiffEntry,
    len: usize,

    pub fn toSlice(self: CAttributedDiffArray) []CAttributedDiffEntry {
        return self.ptr[0..self.len];
    }
};

//
pub const CCommitEntry = extern struct {
    checksum: CSlice,
    subject: CSlice,
};

// A wrapper over pointers to arrays of structures used to pass dynamic lists across the C boundary
pub const CCommitArray = extern struct {
    ptr: [*]CCommitEntry,
    len: usize,

    pub fn toSlice(self: CCommitArray) []CCommitEntry {
        return self.ptr[0..self.len];
    }
};

// // Parameter sets for the сorresponding operation — Rollback
pub const CRollbackRequest = extern struct {
    root_path: CSlice,
    repo_path: CSlice,

    branch: CSlice,

    commit_hash: CSlice,
};

// A set of paths required to initialize the system
pub const CSystemPaths = extern struct {
    repo_path: CSlice,
    root_path: CSlice,
};

// Request structure for initializing the system with branch specification
pub const CInitRequest = extern struct {
    system_paths: CSystemPaths,
    repo_mode: CRepoMode,
    branch: CSlice,
};

// Defines the operating mode of the OSTree repository
pub const CRepoMode = enum(u8) {
    archive = 0,
    bare = 1,
    bare_user = 2,
};

// A listing of all possible return codes used to signal success or specific runtime errors
pub const ErrorCode = enum(i32) {
    ok = 0,

    unexpected = 1,
    out_of_memory = 2,
    invalid_path = 3,
    file_not_found = 4,
    permission_denied = 5,

    lock_would_block = 10,

    db_missing_field = 20,
    db_missing_section = 21,
    db_invalid_entry = 22,
    db_parse_error = 23,

    install_already_installed = 30,
    install_failed = 31,
    install_package_path_not_found = 32,
    install_repo_path_not_found = 33,
    install_checksum_failed = 34,
    install_repo_write_failed = 35,
    install_mtree_insert_failed = 36,
    install_file_already_exists = 37,

    uninstall_not_found = 40,
    uninstall_failed = 41,

    ostree_repo_open = 50,
    ostree_commit = 51,
    ostree_diff = 52,
    ostree_rollback = 53,
    ostree_no_parent = 54,
    ostree_staging_failed = 55,
    ostree_swap_failed = 56,

    already_initialized = 60,
    create_dir_failed = 61,
    ostree_init_failed = 62,
};

// A mapper function that translates internal Zig errors (anyerror) into ErrorCode values understandable by the external interface
pub fn fromError(err: anyerror) ErrorCode {
    return switch (err) {
        // System & File System
        error.OutOfMemory => .out_of_memory,
        error.InvalidPath, error.BadPathName => .invalid_path,
        error.FileNotFound => .file_not_found,
        error.AccessDenied => .permission_denied,
        error.WouldBlock => .lock_would_block,

        // Database
        error.MissingField => .db_missing_field,
        error.MissingSection => .db_missing_section,
        error.InvalidEntry => .db_invalid_entry,
        error.ParseError => .db_parse_error,

        // Init Sequence
        error.RootNotFound => .file_not_found,
        error.AlreadyInitialized => .already_initialized,
        error.CreateDirFailed => .create_dir_failed,
        error.OstreeInitFailed => .ostree_init_failed,

        // Package Management (Install/Uninstall)
        error.AlreadyInstalled => .install_already_installed,
        error.InstallFailed, error.MaxRetriesExceeded => .install_failed,
        error.PackagePathNotFound => .install_package_path_not_found,
        error.RepoPathNotFound => .install_repo_path_not_found,
        error.ChecksumFailed => .install_checksum_failed,
        error.RepoWriteFailed => .install_repo_write_failed,
        error.MtreeInsertFailed => .install_mtree_insert_failed,
        error.FileAlreadyExists => .install_file_already_exists,
        error.PackageNotFound => .uninstall_not_found,
        error.UninstallFailed => .uninstall_failed,
        error.MissingRepository => .ostree_repo_open,

        // OSTree Operations
        error.RepoOpenFailed => .ostree_repo_open,
        error.CommitFailed => .ostree_commit,
        error.DiffFailed => .ostree_diff,
        error.RollbackFailed => .ostree_rollback,
        error.NoPreviousCommit => .ostree_no_parent,
        error.StagingFailed => .ostree_staging_failed,
        error.SwapFailed => .ostree_swap_failed,

        // Fallback for unmapped errors
        else => .unexpected,
    };
}

// The main memory allocator used in the library
var gpa = std.heap.GeneralPurposeAllocator(.{ .safety = true }){};

// Returns the project's Global Allocator (GPA), used for all operations in the FFI layer
pub fn allocator() std.mem.Allocator {
    return gpa.allocator();
}

// A universal exportable function for deallocating memory based on a pointer and length from the calling code
pub export fn upac_free(ptr: *anyopaque, len: usize) callconv(.C) void {
    const slice = @as([*]u8, @ptrCast(ptr))[0..len];
    gpa.allocator().free(slice);
}

// Finalizes the allocator and outputs a warning to the console if any memory leaks were detected during program execution
pub export fn upac_deinit() callconv(.C) void {
    const result = gpa.deinit();
    if (result == .leak) {
        std.debug.print("[upac] WARNING: memory leak detected\n", .{});
    }
}
