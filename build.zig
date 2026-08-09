const std = @import("std");

// Although this function looks imperative, it does not perform the build
// directly and instead it mutates the build graph (`b`) that will be then
// executed by an external runner. The functions in `std.Build` implement a DSL
// for defining build steps and express dependencies between them, allowing the
// build runner to parallelize the build automatically (and the cache system to
// know when a step doesn't need to be re-run).
pub fn build(b: *std.Build) void {
    // Standard target options allow the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native.
    const target = b.standardTargetOptions(.{});
    // Standard optimization options allow the person running `zig build` to
    // select between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall.
    const optimize = b.standardOptimizeOption(.{});

    // The `stilla` module: the library's root source file. This is how
    // dependents import the library (`@import("stilla")`); `addModule`
    // exposes it to consumers of this package.
    const mod = b.addModule("stilla", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Also install a static library artifact (`zig-out/lib/libstilla.a`),
    // which an embedding host written in C or another language can link
    // against directly. Stilla is designed for host integration, so this
    // matters beyond pure-Zig consumers.
    const lib = b.addLibrary(.{
        .name = "stilla",
        .linkage = .static,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(lib);

    // Unit tests, run with `zig build test`. The test executable reuses the
    // `stilla` module (its `test` blocks are reachable through
    // `std.testing.refAllDecls` in root.zig).
    const mod_tests = b.addTest(.{
        .root_module = mod,
    });
    const run_mod_tests = b.addRunArtifact(mod_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_mod_tests.step);
}
