//! HIR M2b black-box suite — the effect-driven consumers (dead-let +
//! selective A-Normal Form, docs/hir.md §11 M2b, docs/effects.md §12).
//! White-box rule tests live in `passes/hir_simplify.zig`; this file runs
//! the pass over real modules through the checker + HIR builder,
//! re-validates structure and effects, checks the acceptance negative
//! cases (trap / host / Unique / cleanup), the fixpoint + determinism,
//! the whole-pipeline corpus with `--simplify`, and consumers-on vs
//! consumers-off interpreter equivalence.
//!
//! Wired into root.zig's test block; run via `zig build test`.

const std = @import("std");
const moduleinfo = @import("moduleinfo.zig");
const checker = @import("passes/checker.zig");
const cfg = @import("cfg.zig");
const hir = @import("hir.zig");
const meta = @import("meta.zig");
const hir_build = @import("passes/hir_build.zig");
const hir_effects = @import("passes/hir_effects.zig");
const hir_simplify = @import("passes/hir_simplify.zig");
const frontend = @import("frontend.zig");
const interpreter = @import("interpreter.zig");
const effects = @import("effects.zig");
const support = @import("interpreter_test_support.zig");
const artifact_bundle = @import("artifact_bundle.zig");
const testing = std.testing;

const CaptureAdapter = support.CaptureAdapter;

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
        if (bdiag.message.len > 0) std.debug.print("HIR builder diag: {s}\n", .{bdiag.message});
        return error.Diagnostic;
    };
    return .{ .arena = arena, .built = built, .graph = graph };
}

/// Run the M2b consumers + the §2.4 re-validation; return the stats.
fn simplifyAll(b: *Built) !hir_simplify.Stats {
    const stats = try hir_simplify.optimize(b.arena.allocator(), b.built, .{ .graph = b.graph });
    for (b.built.funcs.items) |f| {
        const msg = try hir.validate(&b.built.program, f.root, testing.allocator);
        if (msg) |m| {
            defer testing.allocator.free(m);
            std.debug.print("simplify structural validation failed on '{s}': {s}\n", .{ f.name, m });
            return error.TestUnexpectedResult;
        }
    }
    for (b.built.consts.items) |c| {
        const root = c.init orelse continue;
        const msg = try hir.validate(&b.built.program, root, testing.allocator);
        if (msg) |m| {
            defer testing.allocator.free(m);
            std.debug.print("simplify structural validation failed on const '{s}': {s}\n", .{ c.key, m });
            return error.TestUnexpectedResult;
        }
    }
    var an = try hir_effects.Analysis.init(b.arena.allocator(), b.built, .{ .graph = b.graph });
    try an.analyze();
    if (try an.validate(b.arena.allocator())) |m| {
        std.debug.print("simplify effect validation failed: {s}\n", .{m});
        return error.TestUnexpectedResult;
    }
    return stats;
}

/// `simplifyAll` with the embedding's host declarations (docs/effects.md
/// §13): the pass and the re-validation share one effect environment.
fn simplifyAllWith(b: *Built, host_decls: []const effects.HostDecl) !hir_simplify.Stats {
    const stats = try hir_simplify.optimize(b.arena.allocator(), b.built, .{ .graph = b.graph, .host_decls = host_decls });
    var an = try hir_effects.Analysis.init(b.arena.allocator(), b.built, .{ .graph = b.graph, .host_decls = host_decls });
    try an.analyze();
    if (try an.validate(b.arena.allocator())) |m| {
        std.debug.print("simplify effect validation failed: {s}\n", .{m});
        return error.TestUnexpectedResult;
    }
    return stats;
}

fn funcBody(b: *Built, name: []const u8) !hir.ExprId {
    for (b.built.funcs.items) |f| {
        if (std.mem.eql(u8, f.name, name)) {
            return b.built.program.region(b.built.program.regionsOf(f.root)[0]).root;
        }
    }
    return error.TestUnexpectedResult;
}

fn opName(p: *hir.Program, id: hir.ExprId) []const u8 {
    return hir.registry.get(p.node(id).op).name;
}

fn funcText(b: *Built, name: []const u8) ![]u8 {
    for (b.built.funcs.items) |f| {
        if (!std.mem.eql(u8, f.name, name)) continue;
        const text = try hir.print(&b.built.program, f.root, b.arena.allocator(), try b.built.serCtx());
        if (std.mem.startsWith(u8, text, "#refs:")) {
            const nl = std.mem.indexOfScalar(u8, text, '\n') orelse return text;
            return text[nl + 1 ..];
        }
        return text;
    }
    return error.TestUnexpectedResult;
}

// ---------------------------------------------------------------------------
// Rule coverage
// ---------------------------------------------------------------------------

test "M2b: dead let with a discardable init is eliminated" {
    var b = try buildText("app", &.{.{
        "app",
        \\fn pure(x: int32) -> int32 { x + 1 }
        \\fn f(x: int32) -> int32 {
        \\    let unused: int32 = pure(x);
        \\    7
        \\}
    }});
    defer b.deinit();
    const stats = try simplifyAll(&b);
    try testing.expect(stats.dead_lets > 0);
    try testing.expectEqualStrings("fn (B0: i32) => 7i32", try funcText(&b, "app.f"));
}

test "M2b: a trapping division is kept (may-trap is not discardable)" {
    var b = try buildText("app", &.{.{
        "app",
        \\fn f(y: int32) -> int32 {
        \\    let unused: int32 = 10 / y;
        \\    0
        \\}
    }});
    defer b.deinit();
    const stats = try simplifyAll(&b);
    try testing.expectEqual(@as(usize, 0), stats.dead_lets);
    try testing.expectEqualStrings(
        "fn (B0: i32) => let B1: i32 = div.i32(10i32, %B0) in 0i32",
        try funcText(&b, "app.f"),
    );
}

test "M2b: a host call is kept (observable effect)" {
    var b = try buildText("app", &.{.{
        "app",
        \\const builtin = import("builtin");
        \\fn f(x: int32) -> int32 {
        \\    let unused: int32 = builtin.hash(x);
        \\    0
        \\}
    }});
    defer b.deinit();
    const stats = try simplifyAll(&b);
    try testing.expectEqual(@as(usize, 0), stats.dead_lets);
}

test "M2b: a Unique local with a drop hook is not dropped" {
    var b = try buildText("app", &.{.{
        "app",
        \\struct Token { id: int32; drop(t) { let x = t.id; } }
        \\fn make(id: int32) -> Token { Token { id: id } }
        \\fn f(id: int32) -> int32 {
        \\    let unused = make(id);
        \\    0
        \\}
    }});
    defer b.deinit();
    const stats = try simplifyAll(&b);
    try testing.expectEqual(@as(usize, 0), stats.dead_lets);
}

test "M2b: ANF hoists the first non-floatable operand and keeps LTR" {
    var b = try buildText("app", &.{.{
        "app",
        \\const builtin = import("builtin");
        \\fn pure(x: int32) -> int32 { x * 2 }
        \\fn f(x: int32) -> int32 { pure(1) + builtin.hash(x) }
    }});
    defer b.deinit();
    const stats = try simplifyAll(&b);
    try testing.expect(stats.hoists >= 1);
    const body = try funcBody(&b, "app.f");
    const pr = &b.built.program;
    try testing.expectEqualStrings("let", opName(pr, body));
    try testing.expectEqualStrings("call", opName(pr, pr.operands(body)[0]));
    const inner = pr.region(pr.regionsOf(body)[0]).root;
    try testing.expectEqualStrings("add.i32", opName(pr, inner));
    try testing.expectEqualStrings("local", opName(pr, pr.operands(inner)[1]));
}

test "M2b: ANF does not hoist a pure tree" {
    var b = try buildText("app", &.{.{
        "app",
        \\fn f(a: int32, b: int32, c: int32) -> int32 { a + b * c }
    }});
    defer b.deinit();
    const stats = try simplifyAll(&b);
    try testing.expectEqual(@as(usize, 0), stats.hoists);
}

test "M2b: ANF materializes a Unique operand the parent transfers" {
    var b = try buildText("app", &.{.{
        "app",
        \\struct Token { id: int32; drop(t) { let x = t.id; } }
        \\fn make(id: int32) -> Token { Token { id: id } }
        \\fn take(move t: Token) -> int32 { t.id }
        \\fn f(x: int32) -> int32 { take(make(x)) }
    }});
    defer b.deinit();
    const stats = try simplifyAll(&b);
    try testing.expect(stats.hoists >= 1);
    // `take(make(x))` → `let B = make(x) in take(%B)`: the binder is
    // transferred to the call exactly as the anonymous temporary was, so
    // no destructor moves to the let's scope end.
    const body = try funcBody(&b, "app.f");
    const pr = &b.built.program;
    try testing.expectEqualStrings("let", opName(pr, body));
    try testing.expectEqualStrings("call", opName(pr, pr.operands(body)[0]));
    const inner = pr.region(pr.regionsOf(body)[0]).root;
    try testing.expectEqualStrings("call", opName(pr, inner));
    try testing.expectEqualStrings("local", opName(pr, pr.operands(inner)[1]));
}

test "M2b: ANF leaves a Unique operand the parent only borrows in place" {
    var b = try buildText("app", &.{.{
        "app",
        \\struct Token { id: int32; drop(t) { let x = t.id; } }
        \\fn make(id: int32) -> Token { Token { id: id } }
        \\fn show(borrow t: Token) -> int32 { t.id }
        \\fn f(x: int32) -> int32 { show(make(x)) }
    }});
    defer b.deinit();
    const stats = try simplifyAll(&b);
    try testing.expectEqual(@as(usize, 0), stats.hoists);
    const body = try funcBody(&b, "app.f");
    try testing.expectEqualStrings("call", opName(&b.built.program, body));
}

test "M2b: lazy-branch regions are not hoisted across" {
    var b = try buildText("app", &.{.{
        "app",
        \\const builtin = import("builtin");
        \\fn f(c: bool, x: int32) -> int32 {
        \\    if (c) { builtin.hash(x) } else { 0 }
        \\}
    }});
    defer b.deinit();
    const stats = try simplifyAll(&b);
    // The host call sits alone in its branch: nothing to hoist, and the
    // `if` itself is not a StrictLTR parent.
    try testing.expectEqual(@as(usize, 0), stats.hoists);
    const body = try funcBody(&b, "app.f");
    try testing.expectEqualStrings("if", opName(&b.built.program, body));
}

test "M2b: consumers are a fixpoint (second run rewrites nothing)" {
    var b = try buildText("app", &.{.{
        "app",
        \\const builtin = import("builtin");
        \\fn pure(x: int32) -> int32 { x + 1 }
        \\fn f(x: int32) -> int32 {
        \\    let unused: int32 = pure(x);
        \\    pure(1) + builtin.hash(x)
        \\}
    }});
    defer b.deinit();
    const first = try simplifyAll(&b);
    try testing.expect(first.dead_lets + first.hoists > 0);
    const after = try funcText(&b, "app.f");
    const second = try simplifyAll(&b);
    try testing.expectEqual(@as(usize, 0), second.dead_lets + second.hoists);
    try testing.expectEqualStrings(after, try funcText(&b, "app.f"));
}

test "M2b: two fresh builds produce the same text (deterministic)" {
    const src =
        \\const builtin = import("builtin");
        \\fn pure(x: int32) -> int32 { x + 1 }
        \\fn f(x: int32) -> int32 {
        \\    let unused: int32 = pure(x);
        \\    pure(1) + builtin.hash(x)
        \\}
    ;
    var b1 = try buildText("app", &.{.{ "app", src }});
    defer b1.deinit();
    _ = try simplifyAll(&b1);
    var b2 = try buildText("app", &.{.{ "app", src }});
    defer b2.deinit();
    _ = try simplifyAll(&b2);
    try testing.expectEqualStrings(try funcText(&b1, "app.f"), try funcText(&b2, "app.f"));
}

// ---------------------------------------------------------------------------
// Whole-pipeline: opt-in flag, AIR validation + round-trip,
// interpreter differential.
// ---------------------------------------------------------------------------

fn compileAir(spec: []const u8, text: []const u8, simplify: bool) ![]u8 {
    var sources = moduleinfo.Sources{};
    var source_map = std.StringHashMapUnmanaged([]const u8).empty;
    defer source_map.deinit(testing.allocator);
    try source_map.put(testing.allocator, spec, text);
    sources.source = source_map;
    var comp = try frontend.compile(testing.allocator, .{
        .entry = spec,
        .sources = sources,
        .entry_fn = "main",
        .simplify = simplify,
    });
    defer comp.deinit();
    if (comp.program) |*p| return cfg.print(p, testing.allocator);
    if (comp.diag) |d| std.debug.print("simplify pipeline diag: {s}\n", .{d.message});
    return error.TestUnexpectedResult;
}

test "M2b: off by default; enabling rewrites the AIR; both round-trip" {
    const src =
        \\fn pure(x: int32) -> int32 { x + 1 }
        \\fn f(x: int32) -> int32 { let unused: int32 = pure(x); 7 }
        \\fn main() -> void { let _ = f(1); }
    ;
    const off = try compileAir("app", src, false);
    defer testing.allocator.free(off);
    const on = try compileAir("app", src, true);
    defer testing.allocator.free(on);
    try testing.expect(!std.mem.eql(u8, off, on));
    for ([_][]const u8{ off, on }) |air| {
        var p = cfg.Parser.init(testing.allocator);
        defer p.deinit();
        const prog = try p.parse(air);
        try testing.expect(prog.funcs.len > 0);
    }
}

fn capture(text: []const u8, simplify: bool) ![]u8 {
    var state = CaptureAdapter{};
    var l = try support.loadOpts(text, false, false, simplify);
    defer l.deinit();
    var term = try interpreter.runWithEntry(
        testing.allocator,
        l.image,
        try l.fid("main"),
        .{ .userdata = &state, .invoke = CaptureAdapter.invoke },
    );
    defer term.deinit(testing.allocator);
    switch (term) {
        .normal => {},
        .panic => |m| {
            defer testing.allocator.free(m);
            return error.TestUnexpectedResult;
        },
    }
    return testing.allocator.dupe(u8, state.buffer[0..state.len]);
}

test "M2b: consumers-on and consumers-off execute identically" {
    const src =
        \\const builtin = import("builtin");
        \\fn pure(x: int32) -> int32 { x * 2 }
        \\fn calc(v: int32) -> int32 {
        \\    let unused: int32 = pure(v);
        \\    pure(3) + builtin.hash(builtin.str(v))
        \\}
        \\fn main() -> void {
        \\    builtin.print(builtin.str(calc(7)));
        \\    builtin.print(builtin.str(calc(0)));
        \\}
    ;
    const off = try capture(src, false);
    defer testing.allocator.free(off);
    const on = try capture(src, true);
    defer testing.allocator.free(on);
    try testing.expectEqualStrings(off, on);
    // Non-vacuous: the program prints both calls.
    try testing.expect(on.len > 0);
}

test "M2b: a materialized discarded Unique still drops at its statement" {
    // `make(1);` is an anonymous Unique temporary discarded at its full
    // expression. Phase 4 binds it to a synthesized `let`; the sequence's
    // in-place discard must fire the destructor *before* the following
    // statement, not at the enclosing scope end (docs/effects.md §11.2).
    const src =
        \\const builtin = import("builtin");
        \\struct Token { id: int32; drop(t) { builtin.print(builtin.str(t.id)); } }
        \\fn make(id: int32) -> Token { Token { id: id } }
        \\fn take(move t: Token) -> int32 { t.id }
        \\fn main() -> void {
        \\    let first = take(make(1));
        \\    make(2);
        \\    builtin.print(builtin.str(first));
        \\    make(3);
        \\}
    ;
    const off = try capture(src, false);
    defer testing.allocator.free(off);
    const on = try capture(src, true);
    defer testing.allocator.free(on);
    try testing.expectEqualStrings(off, on);
    // `take` drops its parameter (1), then make(2) drops (2), then the
    // printed value, then make(3) drops (3): the drops never float to the
    // end of `main`.
    try testing.expectEqualStrings("1\n2\n1\n3\n", on);
}

// ---------------------------------------------------------------------------
// Corpus: every example / probe compiles through the consumers seam
// ---------------------------------------------------------------------------

fn corpusSimplify(dir: []const u8, spec: []const u8) !void {
    const path = try std.fmt.allocPrint(testing.allocator, "{s}/{s}.st", .{ dir, spec });
    defer testing.allocator.free(path);
    const text = std.Io.Dir.cwd().readFileAlloc(testing.io, path, testing.allocator, .limited(1 << 20)) catch |err| {
        std.debug.print("simplify corpus: cannot read {s} ({s})\n", .{ path, @errorName(err) });
        return error.TestUnexpectedResult;
    };
    defer testing.allocator.free(text);
    const air = compileAir(spec, text, true) catch |err| {
        std.debug.print("simplify corpus: {s} failed to compile with --simplify ({s})\n", .{ path, @errorName(err) });
        return error.TestUnexpectedResult;
    };
    defer testing.allocator.free(air);
    var p = cfg.Parser.init(testing.allocator);
    defer p.deinit();
    _ = p.parse(air) catch |err| {
        std.debug.print("simplify corpus: {s} canonical AIR does not round-trip ({s})\n", .{ path, @errorName(err) });
        return error.TestUnexpectedResult;
    };
}

/// One corpus execution's observable outcome for the consumers-on/off
/// differential: captured output, how the run ended, and the panic
/// message / run error name (docs/hir.md §10.3).
const Term = struct {
    out: []u8,
    end: enum { normal, panic, failed },
    detail: []u8,

    fn deinit(self: *Term) void {
        testing.allocator.free(self.out);
        testing.allocator.free(self.detail);
    }

    fn eql(a: Term, b: Term) bool {
        return a.end == b.end and
            std.mem.eql(u8, a.out, b.out) and
            std.mem.eql(u8, a.detail, b.detail);
    }
};

/// Run one corpus program with the consumers on/off, capturing output,
/// termination, and the panic / error detail. The corpus imports std
/// modules, so the whole-program artifact bundle resolves the imports
/// (the SEG suite's pattern). Each run uses its own arena: the shared
/// `VmHeap` frees only its provenance registry, so this semantic
/// differential does not verify runtime leak-freedom.
fn captureTerm(text: []const u8, simplify: bool) !Term {
    var state = CaptureAdapter{};
    var l = try support.loadOpts(text, false, false, simplify);
    defer l.deinit();
    var bundle_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer bundle_arena.deinit();
    var bundle = try artifact_bundle.ArtifactBundle.build(bundle_arena.allocator(), &(l.compilation.program orelse return error.TestUnexpectedResult));
    var run_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer run_arena.deinit();
    const run_alloc = run_arena.allocator();
    var term = interpreter.runWithEntryAndLoader(
        run_alloc,
        &bundle.root,
        bundle.entry,
        .{ .userdata = &state, .invoke = CaptureAdapter.invoke },
        bundle.loaderHandle(),
    ) catch |err| return .{
        .out = try testing.allocator.dupe(u8, state.buffer[0..state.len]),
        .end = .failed,
        .detail = try testing.allocator.dupe(u8, @errorName(err)),
    };
    defer term.deinit(run_alloc);
    const out = try testing.allocator.dupe(u8, state.buffer[0..state.len]);
    return switch (term) {
        .normal => .{ .out = out, .end = .normal, .detail = try testing.allocator.dupe(u8, "") },
        .panic => |m| .{ .out = out, .end = .panic, .detail = try testing.allocator.dupe(u8, m) },
    };
}

/// Consumers-on and consumers-off interpretation must agree verbatim —
/// output, termination, and panic message (docs/hir.md §10.3).
/// `expect_panic` pins the intended termination so a coincidentally
/// identical failure cannot pass as coverage.
fn corpusDiff(dir: []const u8, spec: []const u8, expect_panic: bool) !void {
    const path = try std.fmt.allocPrint(testing.allocator, "{s}/{s}.st", .{ dir, spec });
    defer testing.allocator.free(path);
    const text = std.Io.Dir.cwd().readFileAlloc(testing.io, path, testing.allocator, .limited(1 << 20)) catch |err| {
        std.debug.print("simplify corpus: cannot read {s} ({s})\n", .{ path, @errorName(err) });
        return error.TestUnexpectedResult;
    };
    defer testing.allocator.free(text);
    var off = try captureTerm(text, false);
    defer off.deinit();
    var on = try captureTerm(text, true);
    defer on.deinit();
    if (off.end == .failed) {
        std.debug.print("simplify corpus: {s} did not run with consumers off: {s} (output {d} bytes)\n", .{ path, off.detail, off.out.len });
        return error.TestUnexpectedResult;
    }
    if (off.end == .panic and std.mem.eql(u8, off.detail, "capture buffer overflow")) {
        std.debug.print("simplify corpus: {s} overflowed the capture buffer\n", .{path});
        return error.TestUnexpectedResult;
    }
    const End = @TypeOf(off.end);
    const want: End = if (expect_panic) .panic else .normal;
    if (off.end != want or on.end != want) {
        std.debug.print("simplify corpus: {s} expected {s} termination, got off={s} {s} / on={s} {s}\n", .{ path, @tagName(want), @tagName(off.end), off.detail, @tagName(on.end), on.detail });
        return error.TestUnexpectedResult;
    }
    if (!Term.eql(off, on)) {
        std.debug.print("simplify corpus: {s} consumers-on/off interpretation differs (off={s} {s}, on={s} {s})\n", .{ path, @tagName(off.end), off.detail, @tagName(on.end), on.detail });
        return error.TestUnexpectedResult;
    }
}

/// Probes whose `main` intentionally traps (`builtin.panic` /
/// unreachable): the differential pins the panic instead of treating it
/// as coverage.
fn probePanics(spec: []const u8) bool {
    return std.mem.eql(u8, spec, "cli_panic") or std.mem.eql(u8, spec, "control_flow");
}

test "M2b corpus — examples/*.st compile+round-trip and consumers-on/off agree" {
    const ex = [_][]const u8{
        "any",    "arrays", "basics",    "box",       "fib",     "fib_tail_call",
        "floats", "fold",   "functions", "generics",  "madd",    "maps",
        "match",  "minmax", "nest",      "ownership", "strings", "structs",
    };
    for (ex) |spec| {
        try corpusSimplify("examples", spec);
        try corpusDiff("examples", spec, false);
    }
}

test "M2b corpus — probes/*.st compile+round-trip and consumers-on/off agree" {
    const pr = [_][]const u8{
        "aggregates",  "any",                "box",         "branch",        "calls",        "casts",
        "cli_panic",   "cli_run",            "comparisons", "constants",     "control_flow", "fusion",
        "generic",     "generic_aggregates", "immediates",  "integer_bits",  "lifecycle",    "list_match",
        "numeric",     "ownership",          "patterns",    "short_circuit", "strings",      "tail_recursion",
        "union_match",
    };
    for (pr) |spec| {
        try corpusSimplify("probes", spec);
        try corpusDiff("probes", spec, probePanics(spec));
    }
}

test "M2b: an observable read declared Write is kept; a Q-only read is discarded" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // The host owns the "read is observable" decision (docs/effects.md
    // §10.1, §13): a read declared as a write is an observable
    // interaction, while a Q-carrying non-observable read is not.
    const write_read = try effects.summaryOf(a, &.{.{ .resource = .{ .host = 1 }, .mode = .write }});
    const q_read = effects.Summary{
        .accesses = (try effects.summaryOf(a, &.{.{ .resource = .{ .host = 1 }, .mode = .read }})).accesses,
        .may_trap = false,
        .may_diverge = false,
        .nondeterministic = true,
    };
    const texts = [_]struct { []const u8, []const u8 }{
        .{ "sensor", "fn read() -> int32;" },
        .{
            "app",
            \\const sensor = import("sensor");
            \\fn f() -> int32 {
            \\    let unused: int32 = sensor.read();
            \\    0
            \\}
        },
    };

    {
        var b = try buildText("app", &texts);
        defer b.deinit();
        const decls = [_]effects.HostDecl{
            .{ .key = "sensor.read", .summary = write_read, .stilla_execution = .forbidden },
        };
        const stats = try simplifyAllWith(&b, &decls);
        try testing.expectEqual(@as(usize, 0), stats.dead_lets);
    }
    {
        var b = try buildText("app", &texts);
        defer b.deinit();
        const decls = [_]effects.HostDecl{
            .{ .key = "sensor.read", .summary = q_read, .stilla_execution = .forbidden },
        };
        const stats = try simplifyAllWith(&b, &decls);
        try testing.expect(stats.dead_lets > 0);
    }
}

// ---------------------------------------------------------------------------
// Full-expression cleanup-token remapping (docs/effects.md §11.2)
// ---------------------------------------------------------------------------

test "M2b: ANF remaps the cleanup token of a hoisted Unique parent" {
    var b = try buildText("app", &.{.{
        "app",
        \\const builtin = import("builtin");
        \\struct Token { id: int32; drop(t) { let x = t.id; } }
        \\fn make(id: int32) -> Token { Token { id: id } }
        \\fn f(x: int32) -> int32 {
        \\    let _ = make(builtin.hash(x));
        \\    7
        \\}
    }});
    defer b.deinit();
    const pr = &b.built.program;

    // Before rewriting: the discarded `make(…)` call is a registered
    // Unique temporary. Locate it as the `call`-origin token.
    var origin: ?hir.ExprId = null;
    for (pr.cleanup_tokens.items) |tk| {
        if (tk.origin_expr == hir.no_expr) continue;
        if (std.mem.eql(u8, opName(pr, tk.origin_expr), "call")) origin = tk.origin_expr;
    }
    try testing.expect(origin != null);
    const idx_before = blk: {
        for (pr.cleanup_tokens.items, 0..) |tk, i| if (tk.origin_expr == origin.?) break :blk i;
        unreachable;
    };
    const reg_before = pr.cleanup_tokens.items[idx_before].registration_index;
    const ty_before = pr.cleanup_tokens.items[idx_before].ty;

    const stats = try simplifyAll(&b);
    try testing.expect(stats.hoists >= 1);

    // The rewritten parent node is now a `let`; the token must have moved
    // to the synthesized inner producer, not stay on the overwritten node.
    try testing.expectEqualStrings("let", opName(pr, origin.?));
    const inner = pr.region(pr.regionsOf(origin.?)[0]).root;
    try testing.expectEqualStrings("call", opName(pr, inner));
    var moved = false;
    for (pr.cleanup_tokens.items) |tk| {
        if (tk.origin_expr != inner) continue;
        moved = true;
        // Relative destruction order (registration_index) and type are
        // preserved by the remap.
        try testing.expectEqual(reg_before, tk.registration_index);
        try testing.expect(meta.Type.eql(ty_before, tk.ty));
    }
    try testing.expect(moved);
    // No live token still names the overwritten node, and no token names
    // a forwarding `let` (which never owns a temporary).
    for (pr.cleanup_tokens.items) |tk| {
        if (tk.origin_expr == hir.no_expr) continue;
        try testing.expect(tk.origin_expr != origin.?);
        try testing.expect(!std.mem.eql(u8, opName(pr, tk.origin_expr), "let"));
    }
}

test "M2b: a Unique binding with a discardable destructor may be dropped" {
    var b = try buildText("app", &.{.{
        "app",
        \\struct Token { id: int32; drop(t) { let x = t.id; } }
        \\fn f(id: int32) -> int32 {
        \\    let unused = Token { id: id };
        \\    7
        \\}
    }});
    defer b.deinit();
    const stats = try simplifyAll(&b);
    try testing.expect(stats.dead_lets > 0);
    try testing.expectEqualStrings("fn (B0: i32) => 7i32", try funcText(&b, "app.f"));
}

test "M2b: a Unique binding with an observable destructor is kept" {
    var b = try buildText("app", &.{
        .{ "hostmod", "fn log(x: int32) -> void;" },
        .{
            "app",
            \\const hostmod = import("hostmod");
            \\struct Token { id: int32; drop(t) { hostmod.log(t.id); } }
            \\fn f(id: int32) -> int32 {
            \\    let unused = Token { id: id };
            \\    7
            \\}
        },
    });
    defer b.deinit();
    const write = try effects.summaryOf(b.arena.allocator(), &.{.{ .resource = .{ .host = 1 }, .mode = .write }});
    const decls = [_]effects.HostDecl{
        .{ .key = "hostmod.log", .summary = write, .stilla_execution = .forbidden },
    };
    const stats = try simplifyAllWith(&b, &decls);
    try testing.expectEqual(@as(usize, 0), stats.dead_lets);
}
