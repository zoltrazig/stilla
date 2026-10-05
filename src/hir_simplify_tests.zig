//! HIR black-box suite — the effect-driven consumers (dead-let +
//! selective A-Normal Form, docs/hir.md §11, docs/effects.md §12).
//! White-box rule tests live in `passes/hir_simplify.zig`; this file runs
//! the pass over real modules through the checker + HIR builder,
//! re-validates structure and effects, checks the acceptance negative
//! cases (trap / host / Unique / cleanup), the fixpoint + determinism,
//! the whole-pipeline corpus with the `hir` gate, and consumers-on vs
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
const rewrite_contract = @import("passes/rewrite_contract.zig");
const frontend = @import("frontend.zig");
const interpreter = @import("interpreter.zig");
const effects = @import("effects.zig");
const support = @import("interpreter_test_support.zig");
const artifact_bundle = @import("artifact_bundle.zig");
const probe_corpus = @import("probe_corpus.zig");
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

/// Run the effect-driven consumers + the §2.4 re-validation; return the stats.
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

/// Collapse every whitespace run to a single space, so the rule assertions
/// compare the *term* the pass produced rather than the printer's line
/// layout (the canonical layout is pinned by the goldens in hir_print.zig).
fn expectFlat(expected: []const u8, actual: []const u8) !void {
    var out = std.ArrayList(u8).empty;
    defer out.deinit(testing.allocator);
    var pending = false;
    for (actual) |ch| {
        if (std.ascii.isWhitespace(ch)) {
            pending = out.items.len > 0;
            continue;
        }
        if (pending) try out.append(testing.allocator, ' ');
        pending = false;
        try out.append(testing.allocator, ch);
    }
    try testing.expectEqualStrings(expected, out.items);
}

// ---------------------------------------------------------------------------
// Rule coverage
// ---------------------------------------------------------------------------

test "consumers: dead let with a discardable init is eliminated" {
    const src = try probe_corpus.read(testing.allocator, "probes/cases", "simplify_dead_let_discardable");
    defer testing.allocator.free(src);
    var b = try buildText("app", &.{.{ "app", src }});
    defer b.deinit();
    const stats = try simplifyAll(&b);
    try testing.expect(stats.dead_lets > 0);
    try expectFlat("fn (B0: i32) { 7i32 }", try funcText(&b, "app.f"));
}

test "consumers: a trapping division is kept (may-trap is not discardable)" {
    const src = try probe_corpus.read(testing.allocator, "probes/cases", "simplify_trapping_div_kept");
    defer testing.allocator.free(src);
    var b = try buildText("app", &.{.{ "app", src }});
    defer b.deinit();
    const stats = try simplifyAll(&b);
    try testing.expectEqual(@as(usize, 0), stats.dead_lets);
    try expectFlat(
        "fn (B0: i32) { let B1: i32 = div.i32(10i32, %B0) { 0i32 } }",
        try funcText(&b, "app.f"),
    );
}

test "consumers: a host call is kept (observable effect)" {
    const src = try probe_corpus.read(testing.allocator, "probes/cases", "simplify_host_call_kept");
    defer testing.allocator.free(src);
    var b = try buildText("app", &.{.{ "app", src }});
    defer b.deinit();
    const stats = try simplifyAll(&b);
    try testing.expectEqual(@as(usize, 0), stats.dead_lets);
}

test "consumers: an unused Unique binding with a purely-reading destructor is dropped" {
    // `let unused = make(id); 0`: the binding is dead and its destructor
    // only reads `t.id`, so the scope-end destruction is discardable and
    // dead-let removes the binding with it (docs/effects.md §11.2 — the
    // scope-end model admits the fold; the old conservative guard kept
    // it). An observable destructor stays (see the negative test below).
    const src = try probe_corpus.read(testing.allocator, "probes/cases", "simplify_unique_dead_pure");
    defer testing.allocator.free(src);
    var b = try buildText("app", &.{.{ "app", src }});
    defer b.deinit();
    const stats = try simplifyAll(&b);
    try testing.expect(stats.dead_lets > 0);
    try expectFlat("fn (B0: i32) { 0i32 }", try funcText(&b, "app.f"));
}

test "consumers: ANF hoists the first non-floatable operand and keeps LTR" {
    const src = try probe_corpus.read(testing.allocator, "probes/cases", "simplify_anf_hoist_ltr");
    defer testing.allocator.free(src);
    var b = try buildText("app", &.{.{ "app", src }});
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

test "consumers: ANF does not hoist a pure tree" {
    const src = try probe_corpus.read(testing.allocator, "probes/cases", "simplify_anf_pure_tree");
    defer testing.allocator.free(src);
    var b = try buildText("app", &.{.{ "app", src }});
    defer b.deinit();
    const stats = try simplifyAll(&b);
    try testing.expectEqual(@as(usize, 0), stats.hoists);
}

test "consumers: ANF materializes a Unique operand the parent transfers" {
    const src = try probe_corpus.read(testing.allocator, "probes/cases", "simplify_anf_unique_transfer");
    defer testing.allocator.free(src);
    var b = try buildText("app", &.{.{ "app", src }});
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

test "consumers: ANF leaves a Unique operand the parent only borrows in place" {
    const src = try probe_corpus.read(testing.allocator, "probes/cases", "simplify_anf_unique_borrow");
    defer testing.allocator.free(src);
    var b = try buildText("app", &.{.{ "app", src }});
    defer b.deinit();
    const stats = try simplifyAll(&b);
    try testing.expectEqual(@as(usize, 0), stats.hoists);
    const body = try funcBody(&b, "app.f");
    try testing.expectEqualStrings("call", opName(&b.built.program, body));
}

test "consumers: lazy-branch regions are not hoisted across" {
    const src = try probe_corpus.read(testing.allocator, "probes/cases", "simplify_lazy_branch");
    defer testing.allocator.free(src);
    var b = try buildText("app", &.{.{ "app", src }});
    defer b.deinit();
    const stats = try simplifyAll(&b);
    // The host call sits alone in its branch: nothing to hoist, and the
    // `if` itself is not a StrictLTR parent.
    try testing.expectEqual(@as(usize, 0), stats.hoists);
    const body = try funcBody(&b, "app.f");
    try testing.expectEqualStrings("if", opName(&b.built.program, body));
}

test "consumers: consumers are a fixpoint (second run rewrites nothing)" {
    const src = try probe_corpus.read(testing.allocator, "probes/cases", "simplify_fixpoint");
    defer testing.allocator.free(src);
    var b = try buildText("app", &.{.{ "app", src }});
    defer b.deinit();
    const first = try simplifyAll(&b);
    try testing.expect(first.dead_lets + first.hoists > 0);
    const after = try funcText(&b, "app.f");
    const second = try simplifyAll(&b);
    try testing.expectEqual(@as(usize, 0), second.dead_lets + second.hoists);
    try testing.expectEqualStrings(after, try funcText(&b, "app.f"));
}

test "consumers: two fresh builds produce the same text (deterministic)" {
    const src = try probe_corpus.read(testing.allocator, "probes/cases", "simplify_fixpoint");
    defer testing.allocator.free(src);
    var b1 = try buildText("app", &.{.{ "app", src }});
    defer b1.deinit();
    _ = try simplifyAll(&b1);
    var b2 = try buildText("app", &.{.{ "app", src }});
    defer b2.deinit();
    _ = try simplifyAll(&b2);
    try testing.expectEqualStrings(try funcText(&b1, "app.f"), try funcText(&b2, "app.f"));
}

test "consumers: a many-operand ANF hoist reaches a true fixpoint (no round cap)" {
    // `simplify_anf_many_operands.st`'s `combine` has nine `app.read()`
    // operands. A read declared `Write` is observable, so
    // `canFloatAsTree` is false for each; selective ANF hoists exactly
    // one (the first non-floatable) per round, because the synthesized
    // `local` left behind is floatable and the first-non-floatable index
    // strictly advances. Nine operands therefore need **nine** changing
    // rounds plus the quiet round that sets `converged` — ten iterations,
    // more than the removed `max_iterations = 8` cap could ever run. The
    // old cap truncated the chain at eight hoists and exited with
    // `converged == false`, so this count is the removal's regression
    // proof (docs/hir.md §5.7, docs/effects.md §12.1).
    const src = try probe_corpus.read(testing.allocator, "probes/cases", "simplify_anf_many_operands");
    defer testing.allocator.free(src);
    var b = try buildText("app", &.{.{ "app", src }});
    defer b.deinit();
    // The read must be observable: a `Write` host summary is what keeps
    // it out of `canFloatAsTree` (docs/effects.md §13).
    const write_read = try effects.summaryOf(b.arena.allocator(), &.{.{ .resource = .{ .host = 1 }, .mode = .write }});
    const decls = [_]effects.HostDecl{
        .{ .key = "app.read", .summary = write_read, .stilla_execution = .forbidden },
    };

    // Nine non-floatable operands in one StrictLTR parent ⇒ nine hoists.
    const hoists: usize = 9;

    const first = try simplifyAllWith(&b, &decls);
    try testing.expect(first.iterations > 8);
    try testing.expect(first.converged);
    try testing.expectEqual(hoists, first.hoists);

    const after = try funcText(&b, "app.f");
    const second = try simplifyAllWith(&b, &decls);
    try testing.expectEqual(@as(usize, 0), second.dead_lets + second.hoists + second.suffix_deletions);
    try testing.expect(second.converged);
    try testing.expectEqualStrings(after, try funcText(&b, "app.f"));
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
        .optimize = .{ .hir = simplify },
    });
    defer comp.deinit();
    if (comp.program) |*p| return cfg.print(p, testing.allocator);
    if (comp.diag) |d| std.debug.print("simplify pipeline diag: {s}\n", .{d.message});
    return error.TestUnexpectedResult;
}

test "consumers: off by default; enabling rewrites the AIR; both round-trip" {
    const src = try probe_corpus.read(testing.allocator, "probes/cases", "simplify_off_by_default_air");
    defer testing.allocator.free(src);
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

test "consumers: the never-suffix rule rewrites the AIR of probes/never_suffix.st" {
    // The CLI enables the CFG optimizer, whose inlining + dead-code
    // removal masks this rule; the pre-optimizer AIR proves the pass
    // actually fires (docs/effects.md §10.1).
    const src = try probe_corpus.read(testing.allocator, "probes", "never_suffix");
    defer testing.allocator.free(src);
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

test "consumers: consumers-on and consumers-off execute identically" {
    const src = try probe_corpus.read(testing.allocator, "probes/cases", "simplify_consumers_exec_identical");
    defer testing.allocator.free(src);
    const off = try capture(src, false);
    defer testing.allocator.free(off);
    const on = try capture(src, true);
    defer testing.allocator.free(on);
    try testing.expectEqualStrings(off, on);
    // Non-vacuous: the program prints both calls.
    try testing.expect(on.len > 0);
}

test "consumers: a materialized discarded Unique still drops at its statement" {
    // `make(1);` is an anonymous Unique temporary discarded at its full
    // expression. The pass binds it to a synthesized `let`; the sequence's
    // in-place discard must fire the destructor *before* the following
    // statement, not at the enclosing scope end (docs/effects.md §11.2).
    const src = try probe_corpus.read(testing.allocator, "probes/cases", "simplify_unique_discard_statement");
    defer testing.allocator.free(src);
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
    const path = try probe_corpus.path(testing.allocator, dir, spec);
    defer testing.allocator.free(path);
    const text = probe_corpus.read(testing.allocator, dir, spec) catch |err| {
        std.debug.print("simplify corpus: cannot read {s} ({s})\n", .{ path, @errorName(err) });
        return error.TestUnexpectedResult;
    };
    defer testing.allocator.free(text);
    const air = compileAir(spec, text, true) catch |err| {
        std.debug.print("simplify corpus: {s} failed to compile with the hir gate ({s})\n", .{ path, @errorName(err) });
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
    const path = try probe_corpus.path(testing.allocator, dir, spec);
    defer testing.allocator.free(path);
    const text = probe_corpus.read(testing.allocator, dir, spec) catch |err| {
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

test "consumers corpus — examples/*.st compile+round-trip and consumers-on/off agree" {
    var corpus = try probe_corpus.list(testing.allocator, "examples");
    defer corpus.deinit();
    for (corpus.names) |spec| {
        try corpusSimplify("examples", spec);
        try corpusDiff("examples", spec, false);
    }
}

test "consumers corpus — probes/*.st compile+round-trip and consumers-on/off agree" {
    var corpus = try probe_corpus.list(testing.allocator, "probes");
    defer corpus.deinit();
    for (corpus.names) |spec| {
        try corpusSimplify("probes", spec);
        try corpusDiff("probes", spec, probe_corpus.panics(spec));
    }
}

test "consumers: an observable read declared Write is kept; a Q-only read is discarded" {
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
    const sensor_src = try probe_corpus.read(testing.allocator, "probes/cases", "simplify_host_read_sensor");
    defer testing.allocator.free(sensor_src);
    const app_src = try probe_corpus.read(testing.allocator, "probes/cases", "simplify_host_read_app");
    defer testing.allocator.free(app_src);
    const texts = [_]struct { []const u8, []const u8 }{
        .{ "sensor", sensor_src },
        .{ "app", app_src },
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

test "consumers: ANF remaps the cleanup token of a hoisted Unique parent" {
    const src = try probe_corpus.read(testing.allocator, "probes/cases", "simplify_cleanup_token_remap");
    defer testing.allocator.free(src);
    var b = try buildText("app", &.{.{ "app", src }});
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
        try testing.expect(ty_before == tk.ty);
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

test "consumers: a Unique binding with a discardable destructor may be dropped" {
    const src = try probe_corpus.read(testing.allocator, "probes/cases", "simplify_unique_discardable_dtor");
    defer testing.allocator.free(src);
    var b = try buildText("app", &.{.{ "app", src }});
    defer b.deinit();
    const stats = try simplifyAll(&b);
    try testing.expect(stats.dead_lets > 0);
    try expectFlat("fn (B0: i32) { 7i32 }", try funcText(&b, "app.f"));
}

test "consumers: a Unique binding with an observable destructor is kept" {
    const hostmod_src = try probe_corpus.read(testing.allocator, "probes/cases", "simplify_unique_observable_dtor_hostmod");
    defer testing.allocator.free(hostmod_src);
    const app_src = try probe_corpus.read(testing.allocator, "probes/cases", "simplify_unique_observable_dtor_app");
    defer testing.allocator.free(app_src);
    var b = try buildText("app", &.{
        .{ "hostmod", hostmod_src },
        .{ "app", app_src },
    });
    defer b.deinit();
    const write = try effects.summaryOf(b.arena.allocator(), &.{.{ .resource = .{ .host = 1 }, .mode = .write }});
    const decls = [_]effects.HostDecl{
        .{ .key = "hostmod.log", .summary = write, .stilla_execution = .forbidden },
    };
    const stats = try simplifyAllWith(&b, &decls);
    try testing.expectEqual(@as(usize, 0), stats.dead_lets);
}

// The rewrite-legality engine (docs/effects.md §10.3, the "unified rewrite
// interface" landed in `passes/rewrite_contract.zig`) answers every
// requirement through a derived query — never an opcode — and fails closed
// when a declared cleanup proof gets a subject of the wrong kind.
test "consumers: the legality engine agrees with the derived queries" {
    var b = try buildText("app", &.{.{
        "app",
        \\fn pure(x: int32) -> int32 { x + 1 }
        \\fn f(x: int32, y: int32) -> int32 {
        \\    let unused: int32 = pure(x);
        \\    let trapped: int32 = 10 / y;
        \\    pure(x) + y
        \\}
    }});
    defer b.deinit();
    const pr = &b.built.program;
    var an = try hir_effects.Analysis.init(b.arena.allocator(), b.built, .{ .graph = b.graph });
    try an.analyze();

    var pure_call: ?hir.ExprId = null;
    var div_node: ?hir.ExprId = null;
    var add_node: ?hir.ExprId = null;
    for (pr.exprs.items, 0..) |_, i| {
        const id: hir.ExprId = @intCast(i);
        const name = opName(pr, id);
        if (std.mem.eql(u8, name, "call")) pure_call = id;
        if (std.mem.eql(u8, name, "div.i32")) div_node = id;
        if (std.mem.eql(u8, name, "add.i32")) add_node = id;
    }
    const call_id = pure_call.?;
    const div_id = div_node.?;
    const add_id = add_node.?;

    // `.discardable` routes to `isDiscardable`; the trap is the negative
    // case (the whole point of §10.2), the pure call the positive one.
    try testing.expect(try an.isDiscardable(call_id));
    try testing.expect(!(try an.isDiscardable(div_id)));
    try testing.expectEqual(
        try an.isDiscardable(call_id),
        try rewrite_contract.check(&an, &.{.discardable}, .{ .expr = call_id }),
    );
    try testing.expectEqual(
        try an.isDiscardable(div_id),
        try rewrite_contract.check(&an, &.{.discardable}, .{ .expr = div_id }),
    );
    // `.duplicable` routes to `isDuplicable`.
    try testing.expectEqual(
        try an.isDuplicable(call_id),
        try rewrite_contract.check(&an, &.{.duplicable}, .{ .expr = call_id }),
    );
    // `.swap_operands` routes to `canSwapOperands` and needs a swap subject:
    // two pure Copy operands are the positive case, a missing subject fails
    // closed.
    try testing.expect(try an.canSwapOperands(add_id, 0, 1));
    try testing.expectEqual(
        try an.canSwapOperands(add_id, 0, 1),
        try rewrite_contract.check(&an, &.{.swap_operands}, .{ .swap = .{ .parent = add_id, .lhs_slot = 0, .rhs_slot = 1 } }),
    );
    try testing.expect(!(try rewrite_contract.check(&an, &.{.swap_operands}, .{ .expr = add_id })));
    // `.evaluation_count_preserved` is the rule's own structural
    // certificate: the engine accepts the declaration without a query.
    try testing.expect(try rewrite_contract.check(&an, &.{.evaluation_count_preserved}, .{ .expr = div_id }));
    // `.materializable` routes to `canMaterializeOperand` and needs a
    // hoist subject: the `add.i32`'s Copy operand is the positive case, a
    // missing or out-of-range subject fails closed.
    try testing.expect(try an.canMaterializeOperand(add_id, 0));
    try testing.expectEqual(
        try an.canMaterializeOperand(add_id, 0),
        try rewrite_contract.check(&an, &.{.materializable}, .{ .hoist = .{ .parent = add_id, .slot = 0 } }),
    );
    try testing.expect(!(try rewrite_contract.check(&an, &.{.materializable}, .{ .expr = add_id })));
    try testing.expect(!(try an.canMaterializeOperand(add_id, 99)));
    try testing.expect(!(try rewrite_contract.check(&an, &.{.materializable}, .{ .hoist = .{ .parent = add_id, .slot = 99 } })));
    // A missing expr subject fails closed rather than dereferencing the
    // `no_expr` sentinel.
    try testing.expect(!(try rewrite_contract.check(&an, &.{.discardable}, .{})));

    // `checkCleanup` refuses a subject whose kind disagrees with the
    // declaration (a drifted declaration fails closed).
    const rule = rewrite_contract.RewriteRule{
        .name = "test",
        .applicability = .shape,
        .contract = .{ .preserves_cleanup = .binder_destruction },
    };
    try testing.expect(!(try rewrite_contract.checkCleanup(rule, &an, .{ .cleanup_free_subtree = call_id })));
}

test "consumers: the materializable requirement routes through canMaterializeOperand" {
    // `.materializable` is selective ANF's ownership/lifetime obligation
    // (docs/effects.md §10.3 / §12.1): a Unique argument is materializable
    // only when the parent transfers it (`Consume`); a borrowed argument
    // under the same parent shape is refused. The engine branch must agree
    // with the derived query in both directions.
    var b = try buildText("app", &.{.{
        "app",
        \\const builtin = import("builtin");
        \\struct Token { id: int32; drop(t) { builtin.print(builtin.str(t.id)); } }
        \\fn make(id: int32) -> Token { Token { id: id } }
        \\fn take(move t: Token) -> int32 { t.id }
        \\fn show(borrow t: Token) -> int32 { t.id }
        \\fn f(x: int32) -> int32 {
        \\    take(make(x)) + show(make(x))
        \\}
    }});
    defer b.deinit();
    const pr = &b.built.program;
    var an = try hir_effects.Analysis.init(b.arena.allocator(), b.built, .{ .graph = b.graph });
    try an.analyze();

    var transferred: ?hir.ExprId = null;
    var borrowed: ?hir.ExprId = null;
    for (pr.exprs.items, 0..) |_, i| {
        const id: hir.ExprId = @intCast(i);
        if (!std.mem.eql(u8, opName(pr, id), "call")) continue;
        const callee = pr.operands(id)[0];
        const name = switch (pr.node(callee).payload) {
            .func => |fr| switch (fr) {
                .func => |fid| if (fid < b.built.funcs.items.len) b.built.funcs.items[fid].name else continue,
                .host => continue,
            },
            else => continue,
        };
        if (std.mem.eql(u8, name, "app.take")) transferred = id;
        if (std.mem.eql(u8, name, "app.show")) borrowed = id;
    }
    const take_id = transferred orelse return error.TestUnexpectedResult;
    const show_id = borrowed orelse return error.TestUnexpectedResult;

    try testing.expect(try an.canMaterializeOperand(take_id, 1));
    try testing.expect(!(try an.canMaterializeOperand(show_id, 1)));
    try testing.expectEqual(
        try an.canMaterializeOperand(take_id, 1),
        try rewrite_contract.check(&an, &.{.materializable}, .{ .hoist = .{ .parent = take_id, .slot = 1 } }),
    );
    try testing.expectEqual(
        try an.canMaterializeOperand(show_id, 1),
        try rewrite_contract.check(&an, &.{.materializable}, .{ .hoist = .{ .parent = show_id, .slot = 1 } }),
    );
}
