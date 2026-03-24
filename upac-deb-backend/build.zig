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

    const shared_library = b.addSharedLibrary(.{
        .name = "upac-backend-deb",
        .root_source_file = b.path("src/backend.zig"),
        .target = target,
        .optimize = optimize,
    });

    linkSysLibs(shared_library);

    b.installArtifact(shared_library);
}
