//! HIR black-box suite — cross-module tests of the AST→HIR builder and
//! the built-program container (hir.md §11 M1a, phase S4; PROGRESS.md).
//! White-box shape tests live in `passes/hir_build.zig` (and hir.zig);
//! this file compiles real modules through phase 1 (module graph) +
//! phase 2 (checker) and builds + validates the HIR over the results.
//!
//! Wired into root.zig's test block; run via `zig build test`.

const std = @import("std");
const moduleinfo = @import("moduleinfo.zig");
const checker = @import("passes/checker.zig");
const hir = @import("hir.zig");
const hir_build = @import("passes/hir_build.zig");
const testing = std.testing;

/// Compile `texts` (specifier → source), check it, and build the HIR.
/// The arena owns everything (graph, annotation, built program).
const Built = struct {
    arena: *std.heap.ArenaAllocator,
    built: *hir.BuiltProgram,
    graph: *moduleinfo.ModuleGraph,

    fn deinit(self: *Built) void {
        self.arena.deinit();
    }
};

fn buildText(entry: []const u8, texts: []const struct { []const u8, []const u8 }) !Built {
    var arena0 = std.heap.ArenaAllocator.init(testing.allocator);
    errdefer arena0.deinit();
    const arena = try arena0.allocator().create(std.heap.ArenaAllocator);
    arena.* = arena0;
    const alloc = arena.allocator();

    var sources = moduleinfo.Sources{};
    var source_map = std.StringHashMapUnmanaged([]const u8).empty;
    for (texts) |pair| try source_map.put(alloc, pair[0], pair[1]);
    sources.source = source_map;

    var builder = moduleinfo.Builder.init(alloc, sources);
    const graph = builder.build(entry) catch |err| switch (err) {
        error.Diagnostic, error.Syntax => return error.Diagnostic,
        else => return err,
    };

    var ck = checker.Checker.init(alloc);
    _ = ck.check(graph) catch return error.Diagnostic;

    var bdiag: moduleinfo.Diag = undefined;
    const built = hir_build.buildProgramDiag(alloc, graph, &ck.annotation, &bdiag) catch {
        // Surface the builder's own diagnostic (span text resolved later
        // by callers with the graph's sources).
        if (bdiag.message.len > 0) std.debug.print("HIR builder diag: {s}\n", .{bdiag.message});
        return error.Diagnostic;
    };
    return .{ .arena = arena, .built = built, .graph = graph };
}

/// Validate every function root of the built program (S3 acceptance:
/// builder output is structurally valid).
fn expectValidAll(built: *const hir.BuiltProgram) !void {
    for (built.funcs.items) |f| {
        const msg = try hir.validate(&built.program, f.root, testing.allocator);
        if (msg) |m| {
            defer testing.allocator.free(m);
            std.debug.print("VALIDATE FAIL func '{s}': {s}\n", .{ f.name, m });
            return error.TestUnexpectedResult;
        }
    }
}

test "S4: build fib-class module and validate every function root" {
    var b = try buildText("app", &.{
        .{
            "app",
            \\const builtin = import("builtin");
            \\fn fib(n: int32) -> int32 {
            \\    if (n < 2) { n } else { fib(n - 1) + fib(n - 2) }
            \\}
            \\fn main() -> void {
            \\    builtin.print(builtin.str(fib(5)));
            \\}
        },
    });
    defer b.deinit();
    // builtin is an embedded host module — it appears as a module record
    // with only host records, no bodies.
    try expectValidAll(b.built);
}

/// The corpus harness: compile every listed module of `dir` as its own
/// entry (each file read from disk at the repo root — `zig build test`
/// runs there, like `zig build examples`), build the HIR, and validate
/// every function root. Deterministic manifest; a module that fails to
/// build or validate is a loud failure (no silent skips).
fn corpusList(dir: []const u8, specs: []const []const u8) !void {
    var failures = std.ArrayList([]const u8).empty;
    defer failures.deinit(testing.allocator);
    for (specs) |spec| {
        const path = try std.fmt.allocPrint(testing.allocator, "{s}/{s}.st", .{ dir, spec });
        defer testing.allocator.free(path);
        const text = std.Io.Dir.cwd().readFileAlloc(testing.io, path, testing.allocator, .limited(1 << 20)) catch |err| {
            std.debug.print("HIR corpus: cannot read {s} ({s})\n", .{ path, @errorName(err) });
            return error.TestUnexpectedResult;
        };
        var b = buildText(spec, &.{.{ spec, text }}) catch |err| {
            std.debug.print("HIR corpus: {s} failed to build: {s}\n", .{ path, @errorName(err) });
            testing.allocator.free(text);
            return error.TestUnexpectedResult;
        };
        defer b.deinit();
        const vmsg = validateAllMsg(b.built);
        if (vmsg) |m| {
            std.debug.print("HIR corpus: {s} failed validation: {s}\n", .{ path, m });
            testing.allocator.free(text);
            return error.TestUnexpectedResult;
        }
        testing.allocator.free(text);
    }
    _ = &failures;
}

fn validateAllMsg(built: *const hir.BuiltProgram) ?[]const u8 {
    for (built.funcs.items) |f| {
        const msg = hir.validate(&built.program, f.root, testing.allocator) catch return "validate oom";
        if (msg) |m| return m;
    }
    return null;
}

test "S4: HIR corpus — examples/*.st build and validate" {
    const ex = [_][]const u8{
        "any",
        "arrays",
        "basics",
        "box",
        "fib",
        "fib_tail_call",
        "floats",
        "fold",
        "functions",
        "generics",
        "madd",
        "maps",
        "match",
        "minmax",
        "nest",
        "ownership",
        "strings",
        "structs",
    };
    try corpusList("examples", &ex);
}

test "S4: HIR corpus — probes/*.st build and validate" {
    const pr = [_][]const u8{
        "aggregates",
        "any",
        "box",
        "branch",
        "calls",
        "casts",
        "cli_panic",
        "cli_run",
        "comparisons",
        "constants",
        "control_flow",
        "fusion",
        "generic",
        "generic_aggregates",
        "immediates",
        "integer_bits",
        "lifecycle",
        "list_match",
        "numeric",
        "ownership",
        "patterns",
        "short_circuit",
        "strings",
        "tail_recursion",
        "union_match",
    };
    try corpusList("probes", &pr);
}
// ---------------------------------------------------------------------------
// S5→S6b: canonical-AIR seam checks (hir.md §10.3/§11 M1a, PROGRESS S5/S6).
// The S5 §10.3 differential (direct vs HIR byte-identical `cfg.print`
// over the corpus) ran green through S6a; S6b deletes the direct path,
// so the corpus gate becomes what remains checkable without an oracle:
// every corpus file compiles through the HIR seam into canonical AIR
// that CFG-validates (inside `frontend.compile`) and round-trips the
// standalone cfg parser.
// ---------------------------------------------------------------------------

const cfg = @import("cfg.zig");
const frontend = @import("frontend.zig");

/// Compile one corpus file through the HIR seam and print its AIR.
fn compileText(entry: []const u8, text: []const u8) ![]u8 {
    var sources = moduleinfo.Sources{};
    var source_map = std.StringHashMapUnmanaged([]const u8).empty;
    defer source_map.deinit(testing.allocator);
    try source_map.put(testing.allocator, entry, text);
    sources.source = source_map;
    var comp = try frontend.compile(testing.allocator, .{ .entry = entry, .sources = sources, .entry_fn = "main" });
    defer comp.deinit();
    if (comp.program) |*p| return cfg.print(p, testing.allocator);
    // A failed compile (an unsupported form or a lowering bug) must
    // surface its diagnostic, not panic on the null program.
    if (comp.diag) |d| {
        std.debug.print("S5 corpus compile failed: {s}\n", .{d.message});
    } else {
        std.debug.print("S5 corpus compile failed (no diagnostic)\n", .{});
    }
    return error.TestUnexpectedResult;
}

/// One corpus file: compile → canonical AIR → standalone cfg-parse
/// round-trip (parse-back must succeed; the frontend already ran the
/// CFG validator inside compile).
fn airRoundTrip(dir: []const u8, spec: []const u8) !void {
    const path = try std.fmt.allocPrint(testing.allocator, "{s}/{s}.st", .{ dir, spec });
    defer testing.allocator.free(path);
    const text = std.Io.Dir.cwd().readFileAlloc(testing.io, path, testing.allocator, .limited(1 << 20)) catch |err| {
        std.debug.print("S5 corpus: cannot read {s} ({s})\n", .{ path, @errorName(err) });
        return error.TestUnexpectedResult;
    };
    defer testing.allocator.free(text);

    const air = try compileText(spec, text);
    defer testing.allocator.free(air);
    var p = cfg.Parser.init(testing.allocator);
    defer p.deinit();
    const prog = p.parse(air) catch |err| {
        std.debug.print("S5 corpus: {s} canonical AIR does not round-trip ({s})\n", .{ path, @errorName(err) });
        return error.TestUnexpectedResult;
    };
    if (prog.funcs.len == 0) {
        std.debug.print("S5 corpus: {s} canonical AIR has no functions\n", .{path});
        return error.TestUnexpectedResult;
    }
}

test "S5: canonical-AIR seam — examples/*.st compile and round-trip" {
    const ex = [_][]const u8{
        "any",
        "arrays",
        "basics",
        "box",
        "fib",
        "fib_tail_call",
        "floats",
        "fold",
        "functions",
        "generics",
        "madd",
        "maps",
        "match",
        "minmax",
        "nest",
        "ownership",
        "strings",
    };
    for (ex) |spec| try airRoundTrip("examples", spec);
}

test "S5: canonical-AIR seam — probes/*.st compile and round-trip" {
    const pr = [_][]const u8{
        "aggregates",
        "any",
        "box",
        "branch",
        "calls",
        "casts",
        "cli_panic",
        "cli_run",
        "comparisons",
        "constants",
        "control_flow",
        "fusion",
        "generic",
        "generic_aggregates",
        "immediates",
        "integer_bits",
        "lifecycle",
        "list_match",
        "numeric",
        "ownership",
        "patterns",
        "short_circuit",
        "strings",
        "tail_recursion",
        "union_match",
    };
    for (pr) |spec| try airRoundTrip("probes", spec);
}

// ---------------------------------------------------------------------------
// S6a+ (now the only place module-value chains are textually checked):
// the corpus has no dotted module path with module-valued members
// (`lib.math.sqrt`, `lists.builtin.print`). The HIR seam records the
// resolved access path on the value leaf and replays `module_ref` +
// per-hop `load_member`s (module identity flows through the AIR, air.md
// §7) — the canonical shape the direct path used to produce. Compile
// through the seam and assert the canonical markers.
// ---------------------------------------------------------------------------

/// Compile a multi-module program through the seam and assert every
/// needle occurs and every absent needle does not, in the AIR text.
fn airMarkers(entry: []const u8, modules: []const struct { []const u8, []const u8 }, needles: []const []const u8, absent: []const []const u8) !void {
    var sources = moduleinfo.Sources{};
    var source_map = std.StringHashMapUnmanaged([]const u8).empty;
    defer source_map.deinit(testing.allocator);
    for (modules) |pair| try source_map.put(testing.allocator, pair[0], pair[1]);
    sources.source = source_map;
    var hc = try frontend.compile(testing.allocator, .{ .entry = entry, .sources = sources, .entry_fn = "main" });
    defer hc.deinit();
    if (hc.program == null) {
        std.debug.print("S5 air markers: compile failed: {s}\n", .{if (hc.diag) |d| d.message else "(no diagnostic)"});
        return error.TestUnexpectedResult;
    }
    const hir_text = try cfg.print(&hc.program.?, testing.allocator);
    defer testing.allocator.free(hir_text);
    for (needles) |n| {
        if (std.mem.indexOf(u8, hir_text, n) == null) {
            std.debug.print("S5 air markers: missing '{s}' in canonical AIR\n", .{n});
            return error.TestUnexpectedResult;
        }
    }
    for (absent) |n| {
        if (std.mem.indexOf(u8, hir_text, n) != null) {
            std.debug.print("S5 air markers: unexpected '{s}' in canonical AIR\n", .{n});
            return error.TestUnexpectedResult;
        }
    }
}

test "S6b: module-value chains replay in canonical AIR" {
    // lib.math.sqrt: the hop `lib.math` loads through lib's member row;
    // the final member loads on that value — never a fresh module ref.
    try airMarkers("app", &.{
        .{ "math", "fn sqrt(x: int32) -> int32 { x }" },
        .{ "lib", "const math = import(\"math\");" },
        .{
            "app",
            \\const lib = import("lib");
            \\fn main() -> void {
            \\    let s = lib.math.sqrt;
            \\    let r = s(4);
            \\}
        },
    }, &.{
        "module \"lib\"",
        "load_member %0, #0", // lib.math (module value row)
        "load_member %1, #0", // math.sqrt on the loaded module value
    }, &.{"module_ref \"math\""}); // no static jump past the hop
    // Same target reached through two different chains, and a deeper
    // chain (lib2 re-exports lib): every path replays its own hops.
    try airMarkers("app", &.{
        .{ "math", "fn sqrt(x: int32) -> int32 { x }" },
        .{ "lib", "const math = import(\"math\");" },
        .{ "lib2", "const lib = import(\"lib\");" },
        .{
            "app",
            \\const lib = import("lib");
            \\const lib2 = import("lib2");
            \\fn main() -> void {
            \\    let a = lib.math.sqrt;
            \\    let b = lib2.lib.math.sqrt;
            \\    let c = lib.math.sqrt;
            \\}
        },
    }, &.{
        "load_member %0, #0", // app.lib
        "load_member %0, #0", // lib.math (via lib)
        "load_member %0, #0", // lib2.lib
        "load_member %0, #0", // lib.math (via lib2.lib)
        "load_member %0, #0", // app.lib (second use, fresh path)
    }, &.{});
    // A host member through a module-valued member of a std module:
    // `lists.builtin.print` — the builtin hop loads, the intrinsic
    // `print` resolves to its wrapper fn_ref with no second member row.
    try airMarkers("app", &.{
        .{
            "app",
            \\const lists = import("list");
            \\fn take(f: fn(str) -> void) -> void { f("hi") }
            \\fn main() -> void { take(lists.builtin.print) }
        },
    }, &.{
        "load_member %0, #6", // list.builtin (compacted canonical index)
        "fn_ref @app.print.intrinsic.0",
    }, &.{"load_member %0, #8"});
}
