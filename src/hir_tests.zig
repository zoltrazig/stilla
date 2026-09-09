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
// S5: HIR→CFG equivalence gate (hir.md §10.3, PROGRESS S5) — the corpus
// must produce byte-identical `cfg.print` text through the direct AST
// lowering and the HIR seam (`frontend.Options.hir_stage`).
// ---------------------------------------------------------------------------

const cfg = @import("cfg.zig");
const frontend = @import("frontend.zig");

/// Compile one corpus file through the HIR seam.
fn compileHir(entry: []const u8, text: []const u8) ![]u8 {
    var sources = moduleinfo.Sources{};
    var source_map = std.StringHashMapUnmanaged([]const u8).empty;
    defer source_map.deinit(testing.allocator);
    try source_map.put(testing.allocator, entry, text);
    sources.source = source_map;
    var comp = try frontend.compile(testing.allocator, .{ .entry = entry, .sources = sources, .entry_fn = "main", .hir_stage = true });
    defer comp.deinit();
    if (comp.program) |*p| return cfg.print(p, testing.allocator);
    // A failed hir_stage compile (an unsupported form or a lowering
    // bug) must surface its diagnostic, not panic on the null program.
    if (comp.diag) |d| {
        std.debug.print("S5 hir_stage compile failed: {s}\n", .{d.message});
    } else {
        std.debug.print("S5 hir_stage compile failed (no diagnostic)\n", .{});
    }
    return error.TestUnexpectedResult;
}

/// The §10.3 gate over one file: direct vs HIR-seam AIR text must be
/// byte-identical (and both paths already CFG-validated inside the
/// frontend compile).
fn diffFile(dir: []const u8, spec: []const u8) !void {
    const path = try std.fmt.allocPrint(testing.allocator, "{s}/{s}.st", .{ dir, spec });
    defer testing.allocator.free(path);
    const text = std.Io.Dir.cwd().readFileAlloc(testing.io, path, testing.allocator, .limited(1 << 20)) catch |err| {
        std.debug.print("S5 diff: cannot read {s} ({s})\n", .{ path, @errorName(err) });
        return error.TestUnexpectedResult;
    };
    defer testing.allocator.free(text);

    var sources = moduleinfo.Sources{};
    var source_map = std.StringHashMapUnmanaged([]const u8).empty;
    defer source_map.deinit(testing.allocator);
    try source_map.put(testing.allocator, spec, text);
    sources.source = source_map;
    var direct = try frontend.compile(testing.allocator, .{ .entry = spec, .sources = sources, .entry_fn = "main" });
    defer direct.deinit();
    const direct_text = try cfg.print(&direct.program.?, testing.allocator);
    defer testing.allocator.free(direct_text);

    const hir_text = try compileHir(spec, text);
    defer testing.allocator.free(hir_text);

    if (!std.mem.eql(u8, direct_text, hir_text)) {
        // Dump both texts for a full side-by-side, then the first
        // differing line for a readable failure.
        std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = "/tmp/stilla_direct.air", .data = direct_text }) catch {};
        std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = "/tmp/stilla_hir.air", .data = hir_text }) catch {};
        // First differing line, for a readable failure.
        var it_d = std.mem.splitScalar(u8, direct_text, '\n');
        var it_h = std.mem.splitScalar(u8, hir_text, '\n');
        var line: usize = 1;
        while (true) {
            const d = it_d.next();
            const h = it_h.next();
            if (d == null and h == null) break;
            if (d == null or h == null or !std.mem.eql(u8, d.?, h.?)) {
                std.debug.print("S5 diff {s}: line {d}\n  direct: {s}\n  hir:    {s}\n", .{ path, line, d orelse "<eof>", h orelse "<eof>" });
                break;
            }
            line += 1;
        }
        return error.TestUnexpectedResult;
    }
}

test "S5: equivalence gate — examples/*.st direct vs HIR AIR text" {
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
    for (ex) |spec| try diffFile("examples", spec);
}

test "S5: equivalence gate — probes/*.st direct vs HIR AIR text" {
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
    for (pr) |spec| try diffFile("probes", spec);
}
