// ── Imports ─────────────────────────────────────────────────────────────────────
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const strip = b.option(bool, "strip", "Strip debug symbols") orelse false;
    const stack_check = b.option(bool, "stack-check", "Check for stack overflows") orelse false;

    // ── Types ─────────────────────────────────────────────────────────────────
    const upac_types = b.addModule("upac-types", .{ .root_source_file = b.path("src/types.zig"), .target = target, .optimize = optimize });

    // ── Database ──────────────────────────────────────────────────────────────
    const upac_data = b.addModule("upac-data", .{ .root_source_file = b.path("src/data/data.zig"), .target = target, .optimize = optimize });
    upac_data.addImport("upac-types", upac_types);

    // ── File FSM ──────────────────────────────────────────────────────────────
    const upac_file = b.addModule("upac-file", .{ .root_source_file = b.path("src/file/file.zig"), .target = target, .optimize = optimize });

    upac_file.linkSystemLibrary("ostree-1", .{ .preferred_link_mode = .dynamic });
    upac_file.linkSystemLibrary("glib-2.0", .{ .preferred_link_mode = .dynamic });
    upac_file.linkSystemLibrary("gio-2.0", .{ .preferred_link_mode = .dynamic });
    upac_file.linkSystemLibrary("gobject-2.0", .{ .preferred_link_mode = .dynamic });

    // ── Installer ─────────────────────────────────────────────────────────────
    const upac_installer = b.addModule("upac-installer", .{ .root_source_file = b.path("src/installer/installer.zig"), .target = target, .optimize = optimize });
    upac_installer.addImport("upac-types", upac_types);
    upac_installer.addImport("upac-file", upac_file);
    upac_installer.addImport("upac-data", upac_data);

    // ── Uninstaller ───────────────────────────────────────────────────────────
    const upac_uninstaller = b.addModule("upac-uninstaller", .{ .root_source_file = b.path("src/uninstaller/uninstaller.zig"), .target = target, .optimize = optimize });
    upac_uninstaller.addImport("upac-types", upac_types);
    upac_uninstaller.addImport("upac-file", upac_file);
    upac_uninstaller.addImport("upac-data", upac_data);

    // ── Rollback ────────────────────────────────────────────────────────────────
    const upac_rollback = b.addModule("upac-rollback", .{ .root_source_file = b.path("src/rollback/rollback.zig"), .target = target, .optimize = optimize });
    upac_rollback.addImport("upac-types", upac_types);
    upac_rollback.addImport("upac-file", upac_file);

    // ── Init ──────────────────────────────────────────────────────────────────
    const upac_init = b.addModule("upac-init", .{ .root_source_file = b.path("src/init.zig"), .target = target, .optimize = optimize });
    upac_init.addImport("upac-file", upac_file);

    // ── Shared library ────────────────────────────────────────────────────────
    const shared_lib = b.addSharedLibrary(.{ .name = "upac", .root_source_file = b.path("src/ffi/export.zig"), .target = target, .optimize = optimize });

    shared_lib.linkLibC();
    shared_lib.linkSystemLibrary("ostree-1");
    shared_lib.linkSystemLibrary("glib-2.0");
    shared_lib.linkSystemLibrary("gio-2.0");
    shared_lib.linkSystemLibrary("gobject-2.0");

    shared_lib.root_module.addImport("upac-types", upac_types);
    shared_lib.root_module.addImport("upac-data", upac_data);

    shared_lib.root_module.addImport("upac-installer", upac_installer);
    shared_lib.root_module.addImport("upac-uninstaller", upac_uninstaller);
    shared_lib.root_module.addImport("upac-rollback", upac_rollback);

    shared_lib.root_module.addImport("upac-init", upac_init);

    shared_lib.root_module.strip = strip;
    shared_lib.root_module.stack_check = stack_check;

    b.installArtifact(shared_lib);
}
