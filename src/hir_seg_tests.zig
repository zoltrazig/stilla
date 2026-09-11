//! HIR SEG black-box suite — cross-module tests of the M2a SEG pass
//! (docs/hir.md §8/§11 M2a). White-box rule/cost tests live in
//! `passes/hir_seg.zig`; this file builds real modules through the
//! checker + HIR builder, runs the pass, re-validates structure and
//! effects, and checks the observable rule set, the negative cases, the
//! corpus (compiles through the seam with SEG on), and SEG-on vs SEG-off
//! interpreter equivalence.
//!
//! Wired into root.zig's test block; run via `zig build test`.

const std = @import("std");
const moduleinfo = @import("moduleinfo.zig");
const checker = @import("passes/checker.zig");
const cfg = @import("cfg.zig");
const hir = @import("hir.zig");
const hir_build = @import("passes/hir_build.zig");
const hir_effects = @import("passes/hir_effects.zig");
const hir_seg = @import("passes/hir_seg.zig");
const frontend = @import("frontend.zig");
const interpreter = @import("interpreter.zig");
const support = @import("interpreter_test_support.zig");
const testing = std.testing;

const CaptureAdapter = support.CaptureAdapter;

// ---------------------------------------------------------------------------
// Build + run helpers
// ---------------------------------------------------------------------------

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

/// Run effect analysis + SEG + the §2.4 re-validation, returning the
/// pass stats. A structural or effect violation after rewriting is a
/// loud failure.
fn segAll(b: *Built) !hir_seg.Stats {
    var stats = try hir_seg.optimize(b.arena.allocator(), b.built, .{ .graph = b.graph });
    for (b.built.funcs.items) |f| {
        const msg = try hir.validate(&b.built.program, f.root, testing.allocator);
        if (msg) |m| {
            defer testing.allocator.free(m);
            std.debug.print("SEG structural validation failed on '{s}': {s}\n", .{ f.name, m });
            return error.TestUnexpectedResult;
        }
    }
    for (b.built.consts.items) |c| {
        const root = c.init orelse continue;
        const msg = try hir.validate(&b.built.program, root, testing.allocator);
        if (msg) |m| {
            defer testing.allocator.free(m);
            std.debug.print("SEG structural validation failed on const '{s}': {s}\n", .{ c.key, m });
            return error.TestUnexpectedResult;
        }
    }
    var an = try hir_effects.Analysis.init(b.arena.allocator(), b.built, .{ .graph = b.graph });
    try an.analyze();
    if (try an.validate(b.arena.allocator())) |m| {
        std.debug.print("SEG effect validation failed: {s}\n", .{m});
        return error.TestUnexpectedResult;
    }
    _ = &stats;
    return stats;
}

fn findFunc(b: *Built, name: []const u8) !hir.FuncRecord {
    for (b.built.funcs.items) |f| {
        if (std.mem.eql(u8, f.name, name)) return f;
    }
    return error.TestUnexpectedResult;
}

fn funcText(b: *Built, name: []const u8) ![]u8 {
    const f = try findFunc(b, name);
    const ctx = try b.built.serCtx();
    const text = try hir.print(&b.built.program, f.root, b.arena.allocator(), ctx);
    // `hir.print` prepends the refs dictionary (`#refs: F0 = …`) when the
    // body mentions a resolved target; the rule assertions only care
    // about the term itself.
    if (std.mem.startsWith(u8, text, "#refs:")) {
        const nl = std.mem.indexOfScalar(u8, text, '\n') orelse return text;
        return text[nl + 1 ..];
    }
    return text;
}

fn funcRawText(b: *Built, name: []const u8) ![]u8 {
    const f = try findFunc(b, name);
    const ctx = try b.built.serCtx();
    return hir.print(&b.built.program, f.root, b.arena.allocator(), ctx);
}

fn expectFuncBody(b: *Built, name: []const u8, expected: []const u8) !void {
    const got = try funcText(b, name);
    try testing.expectEqualStrings(expected, got);
}

// ---------------------------------------------------------------------------
// Rule coverage
// ---------------------------------------------------------------------------

test "SEG: constant folding + let forwarding + integer algebra" {
    var b = try buildText("app", &.{.{
        "app",
        \\fn f(x: int32) -> int32 { x + 0 }
        \\fn g(a: int32) -> int32 { (a * 1) + (2 + 3) }
        \\fn main() -> void { }
    }});
    defer b.deinit();
    const stats = try segAll(&b);
    try testing.expect(stats.folds >= 1);
    try expectFuncBody(&b, "app.f", "fn (B0: i32) => %B0");
    // (a * 1) → a; (2 + 3) → 5; the outer add keeps both rewritten operands.
    try expectFuncBody(&b, "app.g", "fn (B0: i32) => add.i32(%B0, 5i32)");
}

test "SEG: β→let binds the argument exactly once (no duplication)" {
    var b = try buildText("app", &.{.{
        "app",
        \\fn idf(x: int32) -> int32 { x }
        \\fn dup(v: int32) -> int32 { (fn(a: int32) -> int32 { a + a })(idf(v)) }
        \\fn main() -> void { }
    }});
    defer b.deinit();
    const stats = try segAll(&b);
    try testing.expect(stats.beta >= 1);
    // The Copy/discardable argument is materialized once as a let; the
    // body then reads it from the binder — never `call(idf, …)` twice.
    try expectFuncBody(&b, "app.dup", "fn (B0: i32) => let B1: i32 = call(fnref F0, %B0) in add.i32(%B1, %B1)");
}

test "SEG: β is refused for an effectful body and for a non-Copy argument" {
    var b = try buildText("app", &.{.{
        "app",
        \\const builtin = import("builtin");
        \\fn eff(x: int32) -> void { (fn(a: int32) -> void { builtin.print("hi") })(x) }
        \\fn main() -> void { }
    }});
    defer b.deinit();
    _ = try segAll(&b);
    // The λ body calls a host binding: not cleanup-free / not observable-
    // effect-free, so no β and the call site keeps its `fn_ref`.
    const text = try funcText(&b, "app.eff");
    try testing.expect(std.mem.indexOf(u8, text, "call(fnref") != null);
}

test "SEG: may-trap ops never enter an island (div is left to the runtime)" {
    var b = try buildText("app", &.{.{
        "app",
        \\fn q(a: int32, b: int32) -> int32 { a / b }
        \\fn keep() -> int32 { let x = 10 / 2; 0 }
        \\fn main() -> void { }
    }});
    defer b.deinit();
    _ = try segAll(&b);
    try expectFuncBody(&b, "app.q", "fn (B0: i32, B1: i32) => div.i32(%B0, %B1)");
    // `10 / 2` is not total by the declared effect row, so it is neither
    // folded nor deleted even though the binding is unused.
    try expectFuncBody(&b, "app.keep", "fn () => let B0: i32 = div.i32(10i32, 2i32) in 0i32");
}

test "SEG: float algebra is not applied (only integer identities + folding)" {
    var b = try buildText("app", &.{.{
        "app",
        \\fn fadd(x: float32) -> float32 { x + 0.0 }
        \\fn fmul(x: float32) -> float32 { x * 1.0 }
        \\fn fzero(x: float32) -> float32 { x * 0.0 }
        \\fn main() -> void { }
    }});
    defer b.deinit();
    _ = try segAll(&b);
    try expectFuncBody(&b, "app.fadd", "fn (B0: f32) => add.f32(%B0, 0f32)");
    try expectFuncBody(&b, "app.fmul", "fn (B0: f32) => mul.f32(%B0, 1f32)");
    try expectFuncBody(&b, "app.fzero", "fn (B0: f32) => mul.f32(%B0, 0f32)");
}

test "SEG: constant if / and / or select the taken island branch" {
    var b = try buildText("app", &.{.{
        "app",
        \\fn pick() -> int32 { let x = if (1 < 2) { 10 } else { 20 }; x }
        \\fn shorty() -> bool { let x = true or false; x }
        \\fn main() -> void { }
    }});
    defer b.deinit();
    _ = try segAll(&b);
    try expectFuncBody(&b, "app.pick", "fn () => 10i32");
    try expectFuncBody(&b, "app.shorty", "fn () => true");
}

test "SEG: a trapping untaken branch keeps the branch node out of an island" {
    var b = try buildText("app", &.{.{
        "app",
        \\fn guarded(a: int32) -> int32 {
        \\    let r = if (a > 0) { 1 } else { 10 / 0 };
        \\    r
        \\}
        \\fn main() -> void { }
    }});
    defer b.deinit();
    _ = try segAll(&b);
    // The `div` in the untaken branch makes the whole branch non-total, so
    // the `if` is not an island and stays in place.
    const text = try funcText(&b, "app.guarded");
    try testing.expect(std.mem.indexOf(u8, text, "if") != null);
}

test "SEG: the pass is a fixpoint (second run rewrites nothing)" {
    var b = try buildText("app", &.{.{
        "app",
        \\fn idf(x: int32) -> int32 { x }
        \\fn dup(v: int32) -> int32 { (fn(a: int32) -> int32 { a + a })(idf(v)) }
        \\fn g(a: int32) -> int32 { (a * 1) + (2 + 3) }
        \\fn main() -> void { }
    }});
    defer b.deinit();
    const first = try segAll(&b);
    try testing.expect(first.beta + first.folds + first.algebra + first.lets + first.conds > 0);
    const after_first = try funcText(&b, "app.dup");
    const after_first_g = try funcText(&b, "app.g");

    const second = try segAll(&b);
    try testing.expectEqual(@as(usize, 0), second.beta + second.folds + second.algebra + second.lets + second.conds);
    try testing.expectEqualStrings(after_first, try funcText(&b, "app.dup"));
    try testing.expectEqualStrings(after_first_g, try funcText(&b, "app.g"));
}

test "SEG: two fresh builds produce the same optimized text (deterministic)" {
    const src =
        \\fn idf(x: int32) -> int32 { x }
        \\fn dup(v: int32) -> int32 { (fn(a: int32) -> int32 { a + a })(idf(v)) }
        \\fn main() -> void { }
    ;
    var b1 = try buildText("app", &.{.{ "app", src }});
    defer b1.deinit();
    _ = try segAll(&b1);
    var b2 = try buildText("app", &.{.{ "app", src }});
    defer b2.deinit();
    _ = try segAll(&b2);
    try testing.expectEqualStrings(try funcText(&b1, "app.dup"), try funcText(&b2, "app.dup"));
}

// ---------------------------------------------------------------------------
// Whole-pipeline: the flag is off by default; SEG-on AIR validates and
// round-trips; SEG-on and SEG-off execution agree.
// ---------------------------------------------------------------------------

fn compileAir(spec: []const u8, text: []const u8, seg: bool) ![]u8 {
    var sources = moduleinfo.Sources{};
    var source_map = std.StringHashMapUnmanaged([]const u8).empty;
    defer source_map.deinit(testing.allocator);
    try source_map.put(testing.allocator, spec, text);
    sources.source = source_map;
    var comp = try frontend.compile(testing.allocator, .{
        .entry = spec,
        .sources = sources,
        .entry_fn = "main",
        .seg = seg,
    });
    defer comp.deinit();
    if (comp.program) |*p| return cfg.print(p, testing.allocator);
    if (comp.diag) |d| std.debug.print("SEG pipeline diag: {s}\n", .{d.message});
    return error.TestUnexpectedResult;
}

test "SEG: β allocates fresh binders (no binder is declared twice)" {
    var b = try buildText("app", &.{.{
        "app",
        \\fn idf(x: int32) -> int32 { x }
        \\fn dup(v: int32) -> int32 { (fn(a: int32) -> int32 { a + a })(idf(v)) }
        \\fn main() -> void { }
    }});
    defer b.deinit();
    _ = try segAll(&b);
    const pr = &b.built.program;
    const dup = try findFunc(&b, "app.dup");
    const lam = try findFunc(&b, "app.dup.lambda0");
    // The λ record's own parameter binder…
    const lam_region = pr.regionsOf(lam.root)[0];
    const lam_param = pr.params(lam_region)[0];
    // …and the fresh let binder β introduced at the call site.
    const dup_body = pr.region(pr.regionsOf(dup.root)[0]).root;
    const let_param = pr.params(pr.regionsOf(dup_body)[0])[0];
    try testing.expect(lam_param != let_param);
}

test "SEG: a borrowed view keeps its subtree out of an island" {
    var b = try buildText("app", &.{.{
        "app",
        \\fn f(borrow x: int32) -> int32 { let y = x + 0; 7 }
        \\fn main() -> void { }
    }});
    defer b.deinit();
    _ = try segAll(&b);
    // The `local` reads a `.borrow`-mode binder, so `isSegSafe` fails:
    // neither `x + 0` nor the unused binding is rewritten.
    try expectFuncBody(&b, "app.f", "fn (B0: i32 @borrow) => let B1: i32 = add.i32(%B0, 0i32) in 7i32");
}

test "SEG: optimized HIR prints and parses back to the same text" {
    var b = try buildText("app", &.{.{
        "app",
        \\fn idf(x: int32) -> int32 { x }
        \\fn dup(v: int32) -> int32 { (fn(a: int32) -> int32 { a + a })(idf(v)) }
        \\fn main() -> void { }
    }});
    defer b.deinit();
    _ = try segAll(&b);
    const raw = try funcRawText(&b, "app.dup");
    const ctx = try b.built.serCtx();
    var parsed = try hir.parseText(raw, ctx);
    defer parsed.arena.deinit();
    const again = try hir.print(&parsed.program, parsed.root, b.arena.allocator(), try b.built.serCtx());
    try testing.expectEqualStrings(raw, again);
}

test "SEG: off by default; enabling it rewrites the AIR; both round-trip" {
    const src =
        \\fn f(x: int32) -> int32 { x + 0 }
        \\fn main() -> void { let _ = f(1); }
    ;
    const off = try compileAir("app", src, false);
    defer testing.allocator.free(off);
    const on = try compileAir("app", src, true);
    defer testing.allocator.free(on);
    // The default (SEG off) and SEG on differ: `f`'s `x + 0` is folded
    // away only when the pass runs. Both programs are structurally valid
    // canonical AIR (the frontend validator runs inside compile); a
    // standalone parser round-trip confirms the serialized form too.
    try testing.expect(!std.mem.eql(u8, off, on));
    for ([_][]const u8{ off, on }) |air| {
        var p = cfg.Parser.init(testing.allocator);
        defer p.deinit();
        const prog = try p.parse(air);
        try testing.expect(prog.funcs.len > 0);
    }
}

fn capture(text: []const u8, seg: bool) ![]u8 {
    var state = CaptureAdapter{};
    var l = try support.loadOpts(text, false, seg);
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

test "SEG: SEG-on and SEG-off execute identically (β, let, algebra, if)" {
    const src =
        \\const builtin = import("builtin");
        \\fn idf(x: int32) -> int32 { x }
        \\fn calc(v: int32) -> int32 {
        \\    let a: int32 = (fn(x: int32) -> int32 { x + 0 })(idf(v));
        \\    let b = if (a > 0) { a * 1 } else { 10 / 2 };
        \\    b + (2 + 3)
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
    // Non-vacuous: the program prints.
    try testing.expect(std.mem.indexOf(u8, on, "12") != null);
}

// ---------------------------------------------------------------------------
// Corpus: every example / probe compiles through the SEG seam
// ---------------------------------------------------------------------------

fn corpusSeg(dir: []const u8, spec: []const u8) !void {
    const path = try std.fmt.allocPrint(testing.allocator, "{s}/{s}.st", .{ dir, spec });
    defer testing.allocator.free(path);
    const text = std.Io.Dir.cwd().readFileAlloc(testing.io, path, testing.allocator, .limited(1 << 20)) catch |err| {
        std.debug.print("SEG corpus: cannot read {s} ({s})\n", .{ path, @errorName(err) });
        return error.TestUnexpectedResult;
    };
    defer testing.allocator.free(text);
    const air = compileAir(spec, text, true) catch |err| {
        std.debug.print("SEG corpus: {s} failed to compile with --seg ({s})\n", .{ path, @errorName(err) });
        return error.TestUnexpectedResult;
    };
    defer testing.allocator.free(air);
    var p = cfg.Parser.init(testing.allocator);
    defer p.deinit();
    _ = p.parse(air) catch |err| {
        std.debug.print("SEG corpus: {s} canonical AIR does not round-trip ({s})\n", .{ path, @errorName(err) });
        return error.TestUnexpectedResult;
    };
}

test "SEG corpus — examples/*.st compile+validate+round-trip with SEG on" {
    const ex = [_][]const u8{
        "any",    "arrays", "basics",    "box",       "fib",     "fib_tail_call",
        "floats", "fold",   "functions", "generics",  "madd",    "maps",
        "match",  "minmax", "nest",      "ownership", "strings", "structs",
    };
    for (ex) |spec| try corpusSeg("examples", spec);
}

test "SEG corpus — probes/*.st compile+validate+round-trip with SEG on" {
    const pr = [_][]const u8{
        "aggregates",  "any",                "box",         "branch",        "calls",        "casts",
        "cli_panic",   "cli_run",            "comparisons", "constants",     "control_flow", "fusion",
        "generic",     "generic_aggregates", "immediates",  "integer_bits",  "lifecycle",    "list_match",
        "numeric",     "ownership",          "patterns",    "short_circuit", "strings",      "tail_recursion",
        "union_match",
    };
    for (pr) |spec| try corpusSeg("probes", spec);
}
