const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ── Модули ────────────────────────────────────────────────────────────────

    const upac_lock = b.addModule("upac-lock", .{
        .root_source_file = b.path("src/lock/lock.zig"),
    });

    const upac_toml = b.addModule("upac-toml", .{
        .root_source_file = b.path("src/parser/parser.zig"),
    });

    const upac_database = b.addModule("upac-database", .{
        .root_source_file = b.path("src/database/database.zig"),
    });
    upac_database.addImport("upac-toml", upac_toml);
    upac_database.addImport("upac-lock", upac_lock);

    const upac_installer = b.addModule("upac-installer", .{
        .root_source_file = b.path("src/installer/installer.zig"),
    });
    upac_installer.addImport("upac-database", upac_database);

    const upac_uninstaller = b.addModule("upac-uninstaller", .{
        .root_source_file = b.path("src/uninstaller/uninstaller.zig"),
    });
    upac_uninstaller.addImport("upac-database", upac_database);

    const upac_ostree = b.addModule("upac-ostree", .{
        .root_source_file = b.path("src/ostree/ostree.zig"),
    });
    upac_ostree.addImport("upac-lock", upac_lock);
    upac_ostree.addImport("upac-database", upac_database);
    upac_ostree.addIncludePath(.{ .cwd_relative = "/usr/include/ostree-1" });
    upac_ostree.addIncludePath(.{ .cwd_relative = "/usr/include/glib-2.0" });
    upac_ostree.addIncludePath(.{ .cwd_relative = "/usr/lib/glib-2.0/include" });
    upac_ostree.addIncludePath(.{ .cwd_relative = "/usr/include/gio-unix-2.0" });

    const upac_init = b.addModule("upac-init", .{
        .root_source_file = b.path("src/init.zig"),
    });
    upac_init.addIncludePath(.{ .cwd_relative = "/usr/include/ostree-1" });
    upac_init.addIncludePath(.{ .cwd_relative = "/usr/include/glib-2.0" });
    upac_init.addIncludePath(.{ .cwd_relative = "/usr/lib/glib-2.0/include" });
    upac_init.addIncludePath(.{ .cwd_relative = "/usr/include/gio-unix-2.0" });

    const upac_ffi = b.addModule("upac-ffi", .{
        .root_source_file = b.path("src/ffi/exports.zig"),
    });
    upac_ffi.addImport("upac-database", upac_database);
    upac_ffi.addImport("upac-installer", upac_installer);
    upac_ffi.addImport("upac-ostree", upac_ostree);
    upac_ffi.addImport("upac-init", upac_init);

    const linkSysLibs = struct {
        fn call(artifact: *std.Build.Step.Compile) void {
            artifact.linkLibC();
            artifact.linkSystemLibrary("ostree-1");
            artifact.linkSystemLibrary("gio-2.0");
            artifact.linkSystemLibrary("glib-2.0");
            artifact.addIncludePath(.{ .cwd_relative = "/usr/include/ostree-1" });
            artifact.addIncludePath(.{ .cwd_relative = "/usr/include/glib-2.0" });
            artifact.addIncludePath(.{ .cwd_relative = "/usr/lib/glib-2.0/include" });
            artifact.addIncludePath(.{ .cwd_relative = "/usr/include/gio-unix-2.0" });
        }
    }.call;

    // ── Библиотека ────────────────────────────────────────────────────────────
    const shared_lib = b.addSharedLibrary(.{
        .name = "upac",
        .root_source_file = b.path("src/ffi/export.zig"),
        .target = target,
        .optimize = optimize,
    });

    linkSysLibs(shared_lib);

    shared_lib.root_module.addImport("upac-database", upac_database);
    shared_lib.root_module.addImport("upac-installer", upac_installer);
    shared_lib.root_module.addImport("upac-uninstaller", upac_uninstaller);
    shared_lib.root_module.addImport("upac-ostree", upac_ostree);
    shared_lib.root_module.addImport("upac-init", upac_init);

    shared_lib.addIncludePath(.{ .cwd_relative = "/usr/include/ostree-1" });
    shared_lib.addIncludePath(.{ .cwd_relative = "/usr/include/glib-2.0" });
    shared_lib.addIncludePath(.{ .cwd_relative = "/usr/lib/glib-2.0/include" });
    shared_lib.addIncludePath(.{ .cwd_relative = "/usr/include/gio-unix-2.0" });

    b.installArtifact(shared_lib);
}
