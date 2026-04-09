// ── Imports ─────────────────────────────────────────────────────────────────────
const std = @import("std");

const types = @import("types.zig");
const global_types = @import("upac-types");

const installer = @import("upac-installer");
const uninstaller = @import("upac-uninstaller");
const rollback = @import("upac-rollback");

const init = @import("upac-init");

const CSlice = types.CSlice;
const CPackageMeta = types.CPackageMeta;
const CInstallRequest = types.CInstallRequest;
const CUninstallRequest = types.CUninstallRequest;
const CRollbackRequest = types.CRollbackRequest;
const CDiffArray = types.CDiffArray;
const CDiffEntry = types.CDiffEntry;
const CCommitArray = types.CCommitArray;
const CCommitEntry = types.CCommitEntry;
const CSystemPaths = types.CSystemPaths;
const CInitRequest = types.CInitRequest;
const CRepoMode = types.CRepoMode;

const ErrorCode = types.ErrorCode;

// An internal helper function that converts the C struct CPackageMeta to native PackageMeta, translating CSlices into regular slices ([]const u8)
fn toMeta(c_package_meta: CPackageMeta) global_types.PackageMeta {
    return .{
        .name = c_package_meta.name.toSlice(),
        .version = c_package_meta.version.toSlice(),
        .author = c_package_meta.author.toSlice(),
        .description = c_package_meta.description.toSlice(),
        .license = c_package_meta.license.toSlice(),
        .url = c_package_meta.url.toSlice(),
        .installed_at = c_package_meta.installed_at,
        .checksum = c_package_meta.checksum.toSlice(),
    };
}

// The main entry point for package installation. It gathers installation data from the request, initializes the installation engine, and returns an error code as an i32
pub export fn upac_install(c_install_request: CInstallRequest) callconv(.C) i32 {
    const install_data = installer.InstallData{
        .package_meta = toMeta(c_install_request.meta),
        .package_temp_path = c_install_request.package_temp_path.toSlice(),
        .package_checksum = c_install_request.package_checksum.toSlice(),

        .repo_path = c_install_request.repo_path.toSlice(),
        .root_path = c_install_request.root_path.toSlice(),
        .database_path = c_install_request.db_path.toSlice(),

        .branch = c_install_request.branch.toSlice(),

        .max_retries = c_install_request.max_retries,
    };

    installer.InstallerMachine.run(install_data, types.allocator()) catch |err|
        return @intFromEnum(types.fromError(err));

    return @intFromEnum(ErrorCode.ok);
}

// An exported function for deleting a package. It extracts the parameters (paths, package name, retry limits) and initiates the deletion process
pub export fn upac_uninstall(c_uninstall_request: CUninstallRequest) callconv(.C) i32 {
    const uninstall_data = uninstaller.UninstallData{
        .package_name = c_uninstall_request.package_name.toSlice(),

        .repo_path = c_uninstall_request.repo_path.toSlice(),
        .root_path = c_uninstall_request.root_path.toSlice(),
        .db_path = c_uninstall_request.db_path.toSlice(),

        .branch = c_uninstall_request.branch.toSlice(),

        .max_retries = c_uninstall_request.max_retries,
    };

    uninstaller.UninstallerMachine.run(uninstall_data, types.allocator()) catch |err|
        return @intFromEnum(types.fromError(err));

    return @intFromEnum(ErrorCode.ok);
}

// Reverts the system state to a specific commit hash in the OSTree repository
pub export fn upac_rollback(c_rollback_request: CRollbackRequest) callconv(.C) i32 {
    rollback.rollback(c_rollback_request.repo_path.toSlice(), c_rollback_request.branch.toSlice(), c_rollback_request.commit_hash.toSlice(), c_rollback_request.root_path.toSlice(), types.allocator()) catch |err| return @intFromEnum(types.fromError(err));

    return @intFromEnum(ErrorCode.ok);
}

// Compares two states (refs) in a repository and returns an array of changes (CDiffArray). Allocates memory for the entries, which must be freed later
pub export fn upac_diff(c_repo_path: CSlice, c_from_ref: CSlice, c_to_ref: CSlice, c_diff_out: *CDiffArray) callconv(.C) i32 {
    const allocator = types.allocator();

    const diff_entries = rollback.diff(c_repo_path.toSlice(), c_from_ref.toSlice(), c_to_ref.toSlice(), allocator) catch |err| return @intFromEnum(types.fromError(err));

    const c_entries = allocator.alloc(CDiffEntry, diff_entries.len) catch {
        for (diff_entries) |entry| allocator.free(entry.path);
        allocator.free(diff_entries);
        return @intFromEnum(ErrorCode.out_of_memory);
    };

    for (c_entries, 0..) |*c_entry, index| {
        c_entry.* = .{
            .path = CSlice.fromSlice(diff_entries[index].path),
            .kind = @enumFromInt(@intFromEnum(diff_entries[index].kind)),
        };
    }
    allocator.free(diff_entries);

    c_diff_out.* = .{ .ptr = c_entries.ptr, .len = c_entries.len };
    return @intFromEnum(ErrorCode.ok);
}

// Frees all memory allocated for the array of changes and the paths within each CDiffEntry record
pub export fn upac_diff_free(c_diff: *CDiffArray) callconv(.C) void {
    const allocator = types.allocator();
    const entries = c_diff.toSlice();
    for (entries) |entry| allocator.free(entry.path.toSlice());
    allocator.free(entries);
}

// Generates a list of commits for a specified branch. Converts internal commit records into a C-compatible format
pub export fn upac_list_commits(c_repo_path: CSlice, c_branch: CSlice, c_commits: *CCommitArray) callconv(.C) i32 {
    const allocator = types.allocator();

    const commit_entries = rollback.listCommits(
        c_repo_path.toSlice(),
        c_branch.toSlice(),
        allocator,
    ) catch |err| return @intFromEnum(types.fromError(err));

    const c_commit_entries = allocator.alloc(CCommitEntry, commit_entries.len) catch {
        for (commit_entries) |entry| {
            allocator.free(entry.checksum);
            allocator.free(entry.subject);
        }
        allocator.free(commit_entries);
        return @intFromEnum(ErrorCode.out_of_memory);
    };

    for (commit_entries, 0..) |entry, index| {
        c_commit_entries[index] = .{
            .checksum = CSlice.fromSlice(entry.checksum),
            .subject = CSlice.fromSlice(entry.subject),
        };
    }
    allocator.free(commit_entries);

    c_commits.* = .{ .ptr = c_commit_entries.ptr, .len = c_commit_entries.len };
    return @intFromEnum(ErrorCode.ok);
}

// A function for cleaning up memory after retrieving the list of commits; it frees the checksum and header strings
pub export fn upac_commits_free(c_commits: *CCommitArray) callconv(.C) void {
    const allocator = types.allocator();
    const entries = c_commits.toSlice();
    for (entries) |entry| {
        allocator.free(entry.checksum.toSlice());
        allocator.free(entry.subject.toSlice());
    }
    allocator.free(entries);
}

// Initializes system paths and the OSTree repository in the selected mode (archive, bare, etc.)
pub export fn upac_init(c_init_request: CInitRequest) callconv(.C) i32 {
    const system_paths = init.SystemPaths{
        .repo_path = c_init_request.system_paths.repo_path.toSlice(),
        .root_path = c_init_request.system_paths.root_path.toSlice(),
    };

    const repo_mode: init.RepoMode = switch (c_init_request.repo_mode) {
        .archive => .archive,
        .bare => .bare,
        .bare_user => .bare_user,
    };

    const branch = c_init_request.branch.toSlice();

    init.initSystem(system_paths, repo_mode, branch, types.allocator()) catch |err|
        return @intFromEnum(types.fromError(err));

    return @intFromEnum(ErrorCode.ok);
}
