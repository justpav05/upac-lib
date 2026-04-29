// ── Imports ─────────────────────────────────────────────────────────────────────
const list = @import("list.zig");
const std = list.std;
const c_libs = list.c_libs;

const ListMachine = list.ListMachine;
const ListError = list.ListError;

const data = list.data;

const CSlice = list.ffi.CSlice;
const CPackageMeta = list.ffi.CPackageMeta;
const CCommitEntry = list.ffi.CCommitEntry;

const isCancelRequested = list.ffi.isCancelRequested;

const utils = @import("utils.zig");
const getRefBody = utils.getRefBody;
const parsePackageBody = utils.parsePackageBody;
const freeStringMap = utils.freeStringMap;

pub fn stateOpenRepo(machine: *ListMachine, repo_path: [*:0]const u8) ListError!void {
    try machine.check(machine.enter(.open_repo), ListError.AllocFailed);

    const gfile = c_libs.g_file_new_for_path(repo_path);
    defer c_libs.g_object_unref(gfile);

    const repo = c_libs.ostree_repo_new(gfile);
    if (c_libs.ostree_repo_open(repo, machine.cancellable, &machine.gerror) == 0) {
        c_libs.g_object_unref(repo);
        stateFailed(machine);
        return ListError.RepoOpenFailed;
    }
    machine.repo = repo;
}

pub fn stateListPackages(machine: *ListMachine, branch: [*:0]const u8, db_path: []const u8) ListError!void {
    try machine.check(machine.enter(.list_packages), ListError.AllocFailed);

    const repo = try machine.unwrap(machine.repo, ListError.RepoOpenFailed);

    const body = (try machine.check(getRefBody(repo, branch, &machine.gerror, machine.allocator), ListError.AllocFailed)) orelse {
        machine.result_packages = &.{};
        return stateDone(machine);
    };
    defer machine.allocator.free(body);

    var package_map = parsePackageBody(body, machine.allocator) catch {
        machine.result_packages = &.{};
        return stateDone(machine);
    };
    defer freeStringMap(&package_map, machine.allocator);

    var result = std.ArrayList(CPackageMeta).empty;
    errdefer {
        for (result.items) |pkg| {
            machine.allocator.free(pkg.name.toSlice());
            machine.allocator.free(pkg.version.toSlice());
            machine.allocator.free(pkg.architecture.toSlice());
            machine.allocator.free(pkg.description.toSlice());
            machine.allocator.free(pkg.license.toSlice());
            machine.allocator.free(pkg.packager.toSlice());
            machine.allocator.free(pkg.author.toSlice());
            machine.allocator.free(pkg.checksum.toSlice());
            machine.allocator.free(pkg.url.toSlice());
        }
        result.deinit(machine.allocator);
    }

    var iter = package_map.iterator();
    while (iter.next()) |entry| {
        const pkg = data.readMeta(db_path, entry.value_ptr.*, machine.allocator) catch continue;
        try machine.check(result.append(machine.allocator, .{
            .name = CSlice.fromSlice(pkg.name),
            .version = CSlice.fromSlice(pkg.version),
            .architecture = CSlice.fromSlice(pkg.architecture),
            .author = CSlice.fromSlice(pkg.author),
            .description = CSlice.fromSlice(pkg.description),
            .license = CSlice.fromSlice(pkg.license),
            .url = CSlice.fromSlice(pkg.url),
            .packager = CSlice.fromSlice(pkg.packager),
            .checksum = CSlice.fromSlice(pkg.checksum),
            .size = @intCast(pkg.size),
            .installed_at = pkg.installed_at,
        }), ListError.AllocFailed);
    }

    machine.result_packages = try machine.check(result.toOwnedSlice(machine.allocator), ListError.AllocFailed);
    return stateDone(machine);
}

pub fn stateListCommits(machine: *ListMachine, branch: [*:0]const u8) ListError!void {
    try machine.check(machine.enter(.list_commits), ListError.AllocFailed);

    const repo = try machine.unwrap(machine.repo, ListError.RepoOpenFailed);

    var entries = std.ArrayList(CCommitEntry).empty;
    errdefer {
        for (entries.items) |commit_array| {
            machine.allocator.free(commit_array.checksum.toSlice());
            machine.allocator.free(commit_array.subject.toSlice());
        }
        entries.deinit(machine.allocator);
    }

    var current_checksum: [*c]u8 = null;
    defer if (current_checksum != null) c_libs.g_free(current_checksum);

    if (c_libs.ostree_repo_resolve_rev(repo, branch, 0, &current_checksum, &machine.gerror) == 0) {
        machine.result_commits = try machine.check(entries.toOwnedSlice(machine.allocator), ListError.AllocFailed);
        return stateDone(machine);
    }

    var checksum = current_checksum;
    var is_first = true;

    while (checksum != null) {
        if (isCancelRequested()) return ListError.Cancelled;

        var commit_variant: ?*c_libs.GVariant = null;
        if (c_libs.ostree_repo_load_variant(repo, c_libs.OSTREE_OBJECT_TYPE_COMMIT, checksum, &commit_variant, &machine.gerror) == 0) {
            if (!is_first) c_libs.g_free(checksum);
            break;
        }
        defer if (commit_variant) |v| c_libs.g_variant_unref(v);

        const subject_variant = c_libs.g_variant_get_child_value(commit_variant, 3);
        defer if (subject_variant) |variant| c_libs.g_variant_unref(variant);

        var subject_len: usize = 0;
        const subject_ptr = c_libs.g_variant_get_string(subject_variant, &subject_len);

        const checksum_dupe = try machine.check(machine.allocator.dupe(u8, std.mem.span(checksum)), ListError.AllocFailed);
        const subject_dupe = try machine.check(machine.allocator.dupe(u8, subject_ptr[0..subject_len]), ListError.AllocFailed);
        try machine.check(entries.append(machine.allocator, .{
            .checksum = CSlice.fromSlice(checksum_dupe),
            .subject = CSlice.fromSlice(subject_dupe),
        }), ListError.AllocFailed);

        const parent = c_libs.ostree_commit_get_parent(commit_variant);
        if (!is_first) c_libs.g_free(checksum);
        is_first = false;
        checksum = parent;
    }

    machine.result_commits = try machine.check(entries.toOwnedSlice(machine.allocator), ListError.AllocFailed);
    return stateDone(machine);
}

fn stateDone(machine: *ListMachine) ListError!void {
    try machine.check(machine.enter(.done), ListError.AllocFailed);
}

pub fn stateFailed(machine: *ListMachine) void {
    _ = machine.enter(.failed) catch {};
}
