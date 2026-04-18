// ── Imports ─────────────────────────────────────────────────────────────────────
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const strip = b.option(bool, "strip", "Strip debug symbols") orelse false;
    const stack_check = b.option(bool, "stack-check", "Check for stack overflows") orelse false;

    // ── Shared library ────────────────────────────────────────────────────────
    const shared_lib = b.addSharedLibrary(.{
        .name = "upac-rpm",
        .root_source_file = b.path("src/backend.zig"),
        .target = target,
        .optimize = optimize,
    });

    shared_lib.linkLibC();
    shared_lib.linkSystemLibrary2("archive", .{
        .preferred_link_mode = .static,
    });

    shared_lib.root_module.strip = strip;
    shared_lib.root_module.stack_check = stack_check;
    shared_lib.bundle_compiler_rt = true;
    shared_lib.link_gc_sections = false;

    b.installArtifact(shared_lib);
}
