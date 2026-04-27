// ── Imports ─────────────────────────────────────────────────────────────────────
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const strip = b.option(bool, "strip", "Strip debug symbols") orelse false;
    const stack_check = b.option(bool, "stack-check", "Check for stack overflows") orelse false;

    // ── Root ──────────────────────────────────────────────────────────────────
    const upac_root = b.createModule(.{
        .root_source_file = b.path("src/backend.zig"),
        .target = target,
        .optimize = optimize,
    });

    upac_root.strip = strip;
    upac_root.stack_check = stack_check;

    // ── Shared library ────────────────────────────────────────────────────────
    const shared_lib = b.addLibrary(.{
        .name = "upac-deb",
        .linkage = .dynamic,
        .root_module = upac_root,
    });

    shared_lib.linkLibC();
    shared_lib.linkSystemLibrary("archive");

    shared_lib.root_module.strip = strip;
    shared_lib.root_module.stack_check = stack_check;
    shared_lib.bundle_compiler_rt = false;
    shared_lib.link_gc_sections = false;

    b.installArtifact(shared_lib);
}
