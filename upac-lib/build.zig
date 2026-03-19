const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const tomlz_dep = b.dependency("tomlz", .{
        .target = target,
        .optimize = optimize,
    });

    // ── Модули ────────────────────────────────────────────────────────────────

    const upac_lock = b.addModule("upac-lock", .{
        .root_source_file = b.path("src/lock/lock.zig"),
    });

    const upac_database = b.addModule("upac-database", .{
        .root_source_file = b.path("src/database/database.zig"),
    });
    upac_database.addImport("tomlz", tomlz_dep.module("tomlz"));
    upac_database.addImport("upac-lock", upac_lock);

    const upac_installer = b.addModule("upac-installer", .{
        .root_source_file = b.path("src/installer/installer.zig"),
    });
    upac_installer.addImport("upac-lock", upac_lock);
    upac_installer.addImport("upac-database", upac_database);

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
    shared_lib.root_module.addImport("upac-ostree", upac_ostree);
    shared_lib.root_module.addImport("upac-init", upac_init);

    shared_lib.addIncludePath(.{ .cwd_relative = "/usr/include/ostree-1" });
    shared_lib.addIncludePath(.{ .cwd_relative = "/usr/include/glib-2.0" });
    shared_lib.addIncludePath(.{ .cwd_relative = "/usr/lib/glib-2.0/include" });
    shared_lib.addIncludePath(.{ .cwd_relative = "/usr/include/gio-unix-2.0" });

    b.installArtifact(shared_lib);

    // ── Тест базы данных (исполняемый) ────────────────────────────────────────
    const exe = b.addExecutable(.{
        .name = "test_db",
        .root_source_file = b.path("src/tests/db.zig"),
        .target = target,
        .optimize = optimize,
    });
    linkSysLibs(exe);
    exe.root_module.addImport("tomlz", tomlz_dep.module("tomlz"));
    exe.root_module.addImport("upac-lock", upac_lock);
    exe.root_module.addImport("upac-database", upac_database);
    exe.root_module.addImport("upac-init", upac_init);
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // ── Тесты ─────────────────────────────────────────────────────────────────
    const test_step = b.step("test", "Run all tests");

    // Database tests
    const upac_database_tests = b.addTest(.{
        .root_source_file = b.path("src/tests/db.zig"),
        .target = target,
        .optimize = optimize,
    });
    linkSysLibs(upac_database_tests);
    upac_database_tests.root_module.addImport("tomlz", tomlz_dep.module("tomlz"));
    upac_database_tests.root_module.addImport("upac-database", upac_database);
    test_step.dependOn(&b.addRunArtifact(upac_database_tests).step);

    // Installer tests
    const upac_installer_tests = b.addTest(.{
        .root_source_file = b.path("src/tests/installer.zig"),
        .target = target,
        .optimize = optimize,
    });
    linkSysLibs(upac_installer_tests);
    upac_installer_tests.root_module.addImport("tomlz", tomlz_dep.module("tomlz"));
    upac_installer_tests.root_module.addImport("upac-database", upac_database);
    upac_installer_tests.root_module.addImport("upac-installer", upac_installer);
    test_step.dependOn(&b.addRunArtifact(upac_installer_tests).step);

    // Ostree tests
    const upac_ostree_tests = b.addTest(.{
        .root_source_file = b.path("src/tests/ostree.zig"),
        .target = target,
        .optimize = optimize,
    });
    linkSysLibs(upac_ostree_tests);
    upac_ostree_tests.root_module.addImport("tomlz", tomlz_dep.module("tomlz"));
    upac_ostree_tests.root_module.addImport("upac-database", upac_database);
    upac_ostree_tests.root_module.addImport("upac-ostree", upac_ostree);
    test_step.dependOn(&b.addRunArtifact(upac_ostree_tests).step);
}
