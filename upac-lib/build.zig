// ── Imports ─────────────────────────────────────────────────────────────────────
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ── Types ─────────────────────────────────────────────────────────────────
    const upac_types = b.addModule("upac-types", .{
        .root_source_file = b.path("src/types.zig"),
    });

    // ── Database ──────────────────────────────────────────────────────────────
    const upac_data = b.addModule("upac-data", .{
        .root_source_file = b.path("src/data/data.zig"),
    });
    upac_data.addImport("upac-types", upac_types);

    // ── File FSM ──────────────────────────────────────────────────────────────
    const upac_file = b.addModule("upac-file", .{
        .root_source_file = b.path("src/file/file.zig"),
    });

    upac_file.addIncludePath(.{ .cwd_relative = "/usr/include/ostree-1" });
    upac_file.addIncludePath(.{ .cwd_relative = "/usr/include/glib-2.0" });
    upac_file.addIncludePath(.{ .cwd_relative = "/usr/lib/glib-2.0/include" });
    upac_file.addIncludePath(.{ .cwd_relative = "/usr/include/gio-unix-2.0" });

    // ── Installer ─────────────────────────────────────────────────────────────
    const upac_installer = b.addModule("upac-installer", .{
        .root_source_file = b.path("src/installer/installer.zig"),
    });
    upac_installer.addImport("upac-types", upac_types);
    upac_installer.addImport("upac-file", upac_file);
    upac_installer.addImport("upac-data", upac_data);

    // ── Uninstaller ───────────────────────────────────────────────────────────
    const upac_uninstaller = b.addModule("upac-uninstaller", .{
        .root_source_file = b.path("src/uninstaller/uninstaller.zig"),
    });
    upac_uninstaller.addImport("upac-types", upac_types);
    upac_uninstaller.addImport("upac-file", upac_file);
    upac_uninstaller.addImport("upac-data", upac_data);

    // ── Rollback ────────────────────────────────────────────────────────────────
    const upac_rollback = b.addModule("upac-rollback", .{
        .root_source_file = b.path("src/rollback/rollback.zig"),
    });
    upac_rollback.addImport("upac-types", upac_types);
    upac_rollback.addImport("upac-file", upac_file);

    // ── Init ──────────────────────────────────────────────────────────────────
    const upac_init = b.addModule("upac-init", .{
        .root_source_file = b.path("src/init.zig"),
    });

    upac_init.addImport("upac-file", upac_file);

    // ── Shared library ────────────────────────────────────────────────────────
    const shared_lib = b.addSharedLibrary(.{ .name = "upac", .root_source_file = b.path("src/ffi/export.zig"), .target = target, .optimize = optimize });

    shared_lib.linkLibC();
    shared_lib.linkSystemLibrary("ostree-1");
    shared_lib.linkSystemLibrary("gio-2.0");
    shared_lib.linkSystemLibrary("glib-2.0");

    shared_lib.root_module.addImport("upac-types", upac_types);
    shared_lib.root_module.addImport("upac-data", upac_data);

    shared_lib.root_module.addImport("upac-installer", upac_installer);
    shared_lib.root_module.addImport("upac-uninstaller", upac_uninstaller);
    shared_lib.root_module.addImport("upac-rollback", upac_rollback);

    shared_lib.root_module.addImport("upac-init", upac_init);

    b.installArtifact(shared_lib);
}
