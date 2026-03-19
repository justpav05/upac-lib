const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const linkSysLibs = struct {
        fn call(artifact: *std.Build.Step.Compile) void {
            artifact.linkLibC();
            artifact.linkSystemLibrary("archive");
            artifact.addIncludePath(.{ .cwd_relative = "/usr/include" });
        }
    }.call;

    // ── .so ───────────────────────────────────────────────────────────────────
    const lib = b.addSharedLibrary(.{
        .name = "upac-backend-arch",
        .root_source_file = b.path("src/backend.zig"),
        .target = target,
        .optimize = optimize,
    });
    linkSysLibs(lib);
    b.installArtifact(lib);

    // ── Тесты ─────────────────────────────────────────────────────────────────
    const test_step = b.step("test", "Run tests");

    const tests = b.addTest(.{
        .root_source_file = b.path("src/backend.zig"),
        .target = target,
        .optimize = optimize,
    });
    linkSysLibs(tests);
    test_step.dependOn(&b.addRunArtifact(tests).step);
}
