// ── Imports ─────────────────────────────────────────────────────────────────────
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const strip = b.option(bool, "strip", "Strip debug symbols") orelse false;
    const stack_check = b.option(bool, "stack-check", "Check for stack overflows") orelse false;

    // ── Types and ffi ─────────────────────────────────────────────────────────────────
    const upac_ffi = b.createModule(.{
        .root_source_file = b.path("src/ffi/ctypes.zig"),
        .target = target,
        .optimize = optimize,
    });
    upac_ffi.linkSystemLibrary("ostree-1", .{});
    upac_ffi.linkSystemLibrary("glib-2.0", .{});
    upac_ffi.linkSystemLibrary("gio-2.0", .{});
    upac_ffi.linkSystemLibrary("gobject-2.0", .{});

    // ── Database ──────────────────────────────────────────────────────────────
    const upac_data = b.createModule(.{
        .root_source_file = b.path("src/data/data.zig"),
        .target = target,
        .optimize = optimize,
    });
    upac_data.addImport("upac-ffi", upac_ffi);

    // ── Installer ─────────────────────────────────────────────────────────────
    const upac_installer = b.createModule(.{
        .root_source_file = b.path("src/commands/installer/installer.zig"),
        .target = target,
        .optimize = optimize,
    });
    upac_installer.addImport("upac-ffi", upac_ffi);
    upac_installer.addImport("upac-data", upac_data);

    // ── Uninstaller ───────────────────────────────────────────────────────────
    const upac_uninstaller = b.createModule(.{
        .root_source_file = b.path("src/commands/uninstaller/uninstaller.zig"),
        .target = target,
        .optimize = optimize,
    });
    upac_uninstaller.addImport("upac-ffi", upac_ffi);
    upac_uninstaller.addImport("upac-data", upac_data);

    // ── Rollback ────────────────────────────────────────────────────────────────
    const upac_rollback = b.createModule(.{
        .root_source_file = b.path("src/commands/rollback/rollback.zig"),
        .target = target,
        .optimize = optimize,
    });
    upac_rollback.addImport("upac-ffi", upac_ffi);

    // ── Diff ────────────────────────────────────────────────────────────────
    const upac_diff = b.createModule(.{
        .root_source_file = b.path("src/commands/diff/diff.zig"),
        .target = target,
        .optimize = optimize,
    });
    upac_diff.addImport("upac-ffi", upac_ffi);
    upac_diff.addImport("upac-data", upac_data);

    // ── List ────────────────────────────────────────────────────────────────
    const upac_list = b.createModule(.{
        .root_source_file = b.path("src/commands/list/list.zig"),
        .target = target,
        .optimize = optimize,
    });
    upac_list.addImport("upac-ffi", upac_ffi);
    upac_list.addImport("upac-data", upac_data);

    // ── Init ──────────────────────────────────────────────────────────────────
    const upac_init = b.createModule(.{
        .root_source_file = b.path("src/commands/init/init.zig"),
        .target = target,
        .optimize = optimize,
    });
    upac_init.addImport("upac-ffi", upac_ffi);
    upac_init.addImport("upac-data", upac_data);

    // ── Root ──────────────────────────────────────────────────────────────────
    const upac_root = b.createModule(.{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });

    upac_root.strip = strip;
    upac_root.stack_check = stack_check;

    // ── Shared library ────────────────────────────────────────────────────────
    const shared_lib = b.addLibrary(.{
        .name = "upac",
        .linkage = .dynamic,
        .root_module = upac_root,
    });

    shared_lib.linkLibC();

    shared_lib.linkSystemLibrary("ostree-1");
    shared_lib.linkSystemLibrary("glib-2.0");
    shared_lib.linkSystemLibrary("gio-2.0");
    shared_lib.linkSystemLibrary("gobject-2.0");

    shared_lib.root_module.addImport("upac-ffi", upac_ffi);
    shared_lib.root_module.addImport("upac-data", upac_data);

    shared_lib.root_module.addImport("upac-installer", upac_installer);
    shared_lib.root_module.addImport("upac-uninstaller", upac_uninstaller);
    shared_lib.root_module.addImport("upac-rollback", upac_rollback);

    shared_lib.root_module.addImport("upac-diff", upac_diff);
    shared_lib.root_module.addImport("upac-list", upac_list);
    shared_lib.root_module.addImport("upac-init", upac_init);

    b.installArtifact(shared_lib);
}
