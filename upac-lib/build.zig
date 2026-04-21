// ── Imports ─────────────────────────────────────────────────────────────────────
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const ostree_inc_path = b.path("../ostree/src/libostree");
    const ostree_lib_path = b.path("../ostree/.libs");

    const strip = b.option(bool, "strip", "Strip debug symbols") orelse false;
    const stack_check = b.option(bool, "stack-check", "Check for stack overflows") orelse false;

    // ── Types and ffi ─────────────────────────────────────────────────────────────────
    const upac_ffi = b.addModule("upac-ffi", .{ .root_source_file = b.path("src/ffi/ctypes.zig"), .target = target, .optimize = optimize });

    // ── Database ──────────────────────────────────────────────────────────────
    const upac_data = b.addModule("upac-data", .{ .root_source_file = b.path("src/data/data.zig"), .target = target, .optimize = optimize });
    upac_data.addImport("upac-ffi", upac_ffi);

    // ── File FSM ──────────────────────────────────────────────────────────────
    const upac_file = b.addModule("upac-file", .{ .root_source_file = b.path("src/file/file.zig"), .target = target, .optimize = optimize });

    upac_file.addIncludePath(ostree_inc_path);
    upac_file.addLibraryPath(ostree_lib_path);

    upac_file.linkSystemLibrary("ostree-1", .{
        .preferred_link_mode = .static,
        .search_strategy = .no_fallback,
    });

    upac_file.linkSystemLibrary("glib-2.0", .{
        .preferred_link_mode = .dynamic,
        .search_strategy = .no_fallback,
    });
    upac_file.linkSystemLibrary("gio-2.0", .{
        .preferred_link_mode = .dynamic,
        .search_strategy = .no_fallback,
    });
    upac_file.linkSystemLibrary("gobject-2.0", .{
        .preferred_link_mode = .dynamic,
        .search_strategy = .no_fallback,
    });

    // ── Installer ─────────────────────────────────────────────────────────────
    const upac_installer = b.addModule("upac-installer", .{ .root_source_file = b.path("src/commands/installer/installer.zig"), .target = target, .optimize = optimize });
    upac_installer.addImport("upac-ffi", upac_ffi);
    upac_installer.addImport("upac-file", upac_file);
    upac_installer.addImport("upac-data", upac_data);

    // ── Uninstaller ───────────────────────────────────────────────────────────
    const upac_uninstaller = b.addModule("upac-uninstaller", .{ .root_source_file = b.path("src/commands/uninstaller/uninstaller.zig"), .target = target, .optimize = optimize });
    upac_uninstaller.addImport("upac-ffi", upac_ffi);
    upac_uninstaller.addImport("upac-file", upac_file);
    upac_uninstaller.addImport("upac-data", upac_data);

    // ── Rollback ────────────────────────────────────────────────────────────────
    const upac_rollback = b.addModule("upac-rollback", .{ .root_source_file = b.path("src/commands/rollback/rollback.zig"), .target = target, .optimize = optimize });
    upac_rollback.addImport("upac-ffi", upac_ffi);
    upac_rollback.addImport("upac-file", upac_file);

    // ── Diff ────────────────────────────────────────────────────────────────
    const upac_diff = b.addModule("upac-diff", .{ .root_source_file = b.path("src/commands/diff/diff.zig"), .target = target, .optimize = optimize });
    upac_diff.addImport("upac-ffi", upac_ffi);
    upac_diff.addImport("upac-file", upac_file);
    upac_diff.addImport("upac-data", upac_data);

    // ── Init ──────────────────────────────────────────────────────────────────
    const upac_init = b.addModule("upac-init", .{ .root_source_file = b.path("src/commands/init/init.zig"), .target = target, .optimize = optimize });
    upac_init.addImport("upac-ffi", upac_ffi);
    upac_init.addImport("upac-file", upac_file);

    // ── Shared library ────────────────────────────────────────────────────────
    const shared_lib = b.addSharedLibrary(.{ .name = "upac", .root_source_file = b.path("src/lib.zig"), .target = target, .optimize = optimize });

    shared_lib.linkLibC();

    shared_lib.root_module.addImport("upac-ffi", upac_ffi);
    shared_lib.root_module.addImport("upac-data", upac_data);
    shared_lib.root_module.addImport("upac-file", upac_file);

    shared_lib.root_module.addImport("upac-installer", upac_installer);
    shared_lib.root_module.addImport("upac-uninstaller", upac_uninstaller);
    shared_lib.root_module.addImport("upac-rollback", upac_rollback);

    shared_lib.root_module.addImport("upac-diff", upac_diff);
    shared_lib.root_module.addImport("upac-init", upac_init);

    shared_lib.root_module.strip = strip;
    shared_lib.root_module.stack_check = stack_check;
    shared_lib.bundle_compiler_rt = true;
    shared_lib.link_gc_sections = false;

    b.installArtifact(shared_lib);
}
