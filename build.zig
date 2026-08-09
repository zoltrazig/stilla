const std = @import("std");

// `zig build examples` summary step: prints the per-module artifact sizes
// (see the wiring in `build` below). Defined at module scope because Zig
// does not allow nested function declarations.
const ExamplesSummary = struct {
    step: std.Build.Step,
    stems: []const []const u8,
};

fn examplesSize(io: std.Io, path: []const u8) ?u64 {
    const st = std.Io.Dir.cwd().statFile(io, path, .{}) catch return null;
    return st.size;
}

fn makeExamplesSummary(step: *std.Build.Step, options: std.Build.Step.MakeOptions) !void {
    _ = options;
    const self: *ExamplesSummary = @fieldParentPtr("step", step);
    const io = step.owner.graph.io;

    std.debug.print("examples: {d} modules compiled to zig-out/examples/\n", .{self.stems.len});
    std.debug.print("{s:<28} {s:>12} {s:>12} {s:>12}\n", .{ "module", "air", "asm", "bin" });
    var total_air: u64 = 0;
    var total_asm: u64 = 0;
    var total_bin: u64 = 0;
    for (self.stems) |stem| {
        const air = examplesSize(io, step.owner.fmt("zig-out/examples/air/{s}.air", .{stem})) orelse 0;
        const asm_size = examplesSize(io, step.owner.fmt("zig-out/examples/asm/{s}.asm", .{stem})) orelse 0;
        const bin = examplesSize(io, step.owner.fmt("zig-out/examples/bin/{s}.bin", .{stem})) orelse 0;
        total_air += air;
        total_asm += asm_size;
        total_bin += bin;
        std.debug.print("{s:<28} {d:>12} {d:>12} {d:>12}\n", .{ stem, air, asm_size, bin });
    }
    std.debug.print("{s:<28} {d:>12} {d:>12} {d:>12}\n", .{ "total", total_air, total_asm, total_bin });
}

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

    // The standard-library bundle sources (`std/*.st`) live outside the
    // `src/` package root, so `@embedFile` cannot reach them from `src/`.
    // They are embedded by a leaf module rooted at `std/bundle.zig` and
    // imported as `stilla_std_sources` (consumed by `src/stdbundle.zig`).
    mod.addAnonymousImport("stilla_std_sources", .{
        .root_source_file = b.path("std/bundle.zig"),
        .target = target,
        .optimize = optimize,
    });

    // The `stilla` module references itself by name so that subdirectory
    // sources (`src/parse/*.zig`, `src/passes/*.zig`) can import the package
    // root — and through it the top-level modules — as `@import("stilla")`
    // instead of with `../`-relative paths.
    mod.addImport("stilla", mod);

    // Also install a static library artifact (`zig-out/lib/libstilla.a`),
    // which an embedding host written in C or another language can link
    // against directly. Stilla is designed for host integration, so this
    // matters beyond pure-Zig consumers.
    const lib_module = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    lib_module.addAnonymousImport("stilla_std_sources", .{
        .root_source_file = b.path("std/bundle.zig"),
        .target = target,
        .optimize = optimize,
    });
    lib_module.addImport("stilla", lib_module);
    const lib = b.addLibrary(.{
        .name = "stilla",
        .linkage = .static,
        .root_module = lib_module,
    });
    b.installArtifact(lib);

    // The `stilla` frontend compiler: Stilla source → AIR text. The
    // embedded `std/` bundle travels with the `stilla` module.
    const exe_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_module.addImport("stilla", mod);
    const exe = b.addExecutable(.{
        .name = "stilla",
        .root_module = exe_module,
    });
    b.installArtifact(exe);

    // `zig build run -- <input> [options]`: build and run the frontend
    // compiler. This is the fastest way to compile a Stilla file to AIR
    // text (or, with `--emit-asm`, to LLIR assembly, with `--emit-bin
    // <file>` to bytecode, or with `--run` to execution) from a checkout.
    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |args| run_cmd.addArgs(args);
    // No input on the command line (e.g. `zig build run -- --run`) would
    // run `stilla` with a missing input and fail; default the input to
    // examples/fib.st so the run step always executes something real.
    if (!argsNameInput(b.args)) run_cmd.addArg("examples/fib.st");
    const run_step = b.step("run", "Compile a Stilla file to AIR, LLIR asm, or LLIR bin — or execute with --run");
    run_step.dependOn(&run_cmd.step);

    // Unit tests, run with `zig build test`. The test executable reuses the
    // `stilla` module (its `test` blocks are reachable through
    // `std.testing.refAllDecls` in root.zig).
    const mod_tests = b.addTest(.{
        .root_module = mod,
    });
    const run_mod_tests = b.addRunArtifact(mod_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_mod_tests.step);

    // The CLI frontend (`src/main.zig`) is a separate artifact; its own
    // `test` blocks (arg parsing + the `--output` end-to-end sink) run
    // against the exe module.
    const exe_tests = b.addTest(.{
        .root_module = exe_module,
    });
    const run_exe_tests = b.addRunArtifact(exe_tests);
    test_step.dependOn(&run_exe_tests.step);

    // 5.3 stdout probe: the fd-1 sink of the compiler can't run in the
    // `zig build test` process (fd 1 is the test-runner's `--listen`
    // protocol pipe), so it is probed here as a real subprocess — run the
    // compiled `stilla` with `--emit-asm` on an example and assert that
    // stdout carries the symbolic LLIR assembly. Together with the
    // `--output` file-sink test in `src/main.zig`, both sinks of the
    // `--emit-asm` flag are covered.
    const asm_probe = b.addRunArtifact(exe);
    asm_probe.addArgs(&.{ "--emit-asm", "examples/madd.st" });
    asm_probe.expectStdOutMatch("; LLIR assembly — symbolic projection");
    asm_probe.expectStdOutMatch("func @madd.poly {");
    asm_probe.expectStdOutMatch(".block $madd.poly.entry");
    test_step.dependOn(&asm_probe.step);

    // 13 M5 `--run` probes: the `--run` stdout sink is the fd-1 path that
    // cannot run in the `zig build test` process (the test-runner's
    // `--listen` protocol pipe — see the note in `src/main.zig`), so the
    // full process is probed here as a real subprocess. The source and
    // binary runs print the same golden line; `helper` lowers before
    // `main`, so the binary run prints it only if the header's entry id
    // (main, not function 0) is honored (D3).
    const run_probe = b.addRunArtifact(exe);
    run_probe.addArgs(&.{ "--run", "probes/cli_run.st" });
    run_probe.expectStdOutEqual("42\n");
    test_step.dependOn(&run_probe.step);

    // The self-contained binary path: emit, then run the emitted file.
    // The emit step declares no output args, so it always re-runs and the
    // .bc reflects the current sources (same pattern as the examples).
    std.Io.Dir.cwd().createDirPath(b.graph.io, "zig-out/probes") catch {};
    const bin_emit = b.addRunArtifact(exe);
    bin_emit.addArgs(&.{ "--emit-bin", "zig-out/probes/cli_run.bc", "probes/cli_run.st" });
    const bin_run = b.addRunArtifact(exe);
    bin_run.addArgs(&.{ "--run", "zig-out/probes/cli_run.bc" });
    bin_run.step.dependOn(&bin_emit.step);
    bin_run.expectStdOutEqual("42\n");
    test_step.dependOn(&bin_run.step);

    // Panic terminates with exit 1 and names the trap site on stderr
    // (`Termination.panic`, interpreter_types.zig): the CLI prints the
    // owned message verbatim.
    const panic_probe = b.addRunArtifact(exe);
    panic_probe.addArgs(&.{ "--run", "probes/cli_panic.st" });
    panic_probe.expectExitCode(1);
    panic_probe.expectStdErrMatch("panic in cli_panic#");
    panic_probe.expectStdErrMatch("probe boom");
    test_step.dependOn(&panic_probe.step);

    // Load/compile errors exit 2: a stream with the LLIR magic but a
    // foreign version is rejected on magic/version alone (spec §8.3), and
    // a source that fails to compile reports a diagnostic.
    const bad_bin_probe = b.addRunArtifact(exe);
    bad_bin_probe.addArgs(&.{ "--run", "probes/cli_bad.bc" });
    bad_bin_probe.expectExitCode(2);
    bad_bin_probe.expectStdErrMatch("not a valid LLIR binary");
    test_step.dependOn(&bad_bin_probe.step);

    const bad_src_probe = b.addRunArtifact(exe);
    bad_src_probe.addArgs(&.{ "--run", "probes/cli_compile_error.txt" });
    bad_src_probe.expectExitCode(2);
    bad_src_probe.expectStdErrMatch("error:");
    test_step.dependOn(&bad_src_probe.step);

    // ------------------------------------------------------------------
    // `zig build examples`: compile every examples/*.st into three output
    // artifacts — CFG AIR text, LLIR assembly, and LLIR binary — under
    // zig-out/examples/, then print a per-module size summary. The compile
    // steps declare no output args, so the run steps are never cached and
    // artifacts always reflect the current sources.
    //
    // CLI shapes per kind (src/main.zig):
    //   air: --output zig-out/examples/air/<stem>.air
    //   asm: --emit-asm --output zig-out/examples/asm/<stem>.asm
    //   bin: --emit-bin zig-out/examples/bin/<stem>.bin

    // Discover the examples at configure time so new .st files join
    // automatically; a missing examples/ dir degrades to an empty build
    // with a warning rather than failing configure (which would break
    // unrelated steps like `zig build test`).
    var stems: std.ArrayList([]const u8) = .empty;
    if (std.Io.Dir.cwd().openDir(b.graph.io, "examples", .{ .iterate = true })) |*dir| {
        defer dir.close(b.graph.io);
        var it = dir.iterate();
        while (it.next(b.graph.io) catch null) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".st")) continue;
            stems.append(b.allocator, b.allocator.dupe(u8, entry.name[0 .. entry.name.len - 3]) catch @panic("OOM")) catch @panic("OOM");
        }
    } else |_| {
        std.debug.print("examples: 'examples/' not found; nothing to compile\n", .{});
    }
    std.mem.sort([]const u8, stems.items, {}, struct {
        fn lt(_: void, a: []const u8, b2: []const u8) bool {
            return std.mem.lessThan(u8, a, b2);
        }
    }.lt);

    // The stilla CLI writes output files without creating parent
    // directories, so ensure the artifact dirs exist up front.
    std.Io.Dir.cwd().createDirPath(b.graph.io, "zig-out/examples/air") catch {};
    std.Io.Dir.cwd().createDirPath(b.graph.io, "zig-out/examples/asm") catch {};
    std.Io.Dir.cwd().createDirPath(b.graph.io, "zig-out/examples/bin") catch {};

    const examples_step = b.step("examples", "Compile examples/ to AIR, LLIR asm, and LLIR bin artifacts and summarize sizes");

    var summary = b.allocator.create(ExamplesSummary) catch @panic("OOM");
    summary.* = .{
        .stems = stems.items,
        .step = std.Build.Step.init(.{
            .id = .custom,
            .name = "examples-summary",
            .owner = b,
            .makeFn = makeExamplesSummary,
        }),
    };
    examples_step.dependOn(&summary.step);

    for (stems.items) |stem| {
        const src = b.fmt("examples/{s}.st", .{stem});

        const air = b.addRunArtifact(exe);
        air.addArgs(&.{ "--output", b.fmt("zig-out/examples/air/{s}.air", .{stem}), src });
        summary.step.dependOn(&air.step);

        const asm_run = b.addRunArtifact(exe);
        asm_run.addArgs(&.{ "--emit-asm", "--output", b.fmt("zig-out/examples/asm/{s}.asm", .{stem}), src });
        summary.step.dependOn(&asm_run.step);

        const bin = b.addRunArtifact(exe);
        bin.addArgs(&.{ "--emit-bin", b.fmt("zig-out/examples/bin/{s}.bin", .{stem}), src });
        summary.step.dependOn(&bin.step);
    }
}

/// True if the `--` args already name an input file: a positional token
/// after option parsing (Unix order — options precede the input), skipping
/// the values of value-taking options (`--output`, `--module`, `--entry-fn`,
/// `--emit-bin`, `-I`) so `--module app` is not mistaken for an input.
fn argsNameInput(args: ?[]const []const u8) bool {
    const list = args orelse return false;
    var i: usize = 0;
    var parse_options = true;
    while (i < list.len) : (i += 1) {
        const a = list[i];
        if (parse_options and std.mem.eql(u8, a, "--")) {
            parse_options = false;
        } else if (parse_options and (std.mem.eql(u8, a, "--output") or
            std.mem.eql(u8, a, "--module") or std.mem.eql(u8, a, "--entry-fn") or
            std.mem.eql(u8, a, "--emit-bin") or std.mem.eql(u8, a, "-I")))
        {
            i += 1; // the option's value, not the input
        } else if (parse_options and a.len > 0 and a[0] == '-') {
            // a flag option; nothing to skip
        } else {
            return true; // a positional: the input file
        }
    }
    return false;
}
