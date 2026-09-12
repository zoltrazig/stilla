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
const artifact_bundle = @import("artifact_bundle.zig");
const probe_corpus = @import("probe_corpus.zig");
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

/// Structural + effect re-validation of the post-rewrite tree (hir.md
/// §2.4): every rewrite consumer in this suite runs it, including the
/// single-round `segOnce`. A violation is a loud failure.
fn revalidateRewritten(b: *Built) !void {
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
}

/// Run effect analysis + SEG + the §2.4 re-validation, returning the
/// pass stats.
fn segAll(b: *Built) !hir_seg.Stats {
    const stats = try hir_seg.optimize(b.arena.allocator(), b.built, .{ .graph = b.graph });
    try revalidateRewritten(b);
    return stats;
}

/// A fresh effect analysis of the current (pre-rewrite) built program —
/// for asserting the admission predicate directly.
fn analysisOf(b: *Built) !hir_effects.Analysis {
    var an = try hir_effects.Analysis.init(b.arena.allocator(), b.built, .{ .graph = b.graph });
    try an.analyze();
    return an;
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
    const src = try probe_corpus.read(testing.allocator, "probes/cases", "seg_constant_folding");
    defer testing.allocator.free(src);
    var b = try buildText("app", &.{.{ "app", src }});
    defer b.deinit();
    const stats = try segAll(&b);
    try testing.expect(stats.folds >= 1);
    try expectFuncBody(&b, "app.f", "fn (B0: i32) => %B0");
    // (a * 1) → a; (2 + 3) → 5; the outer add keeps both rewritten operands.
    try expectFuncBody(&b, "app.g", "fn (B0: i32) => add.i32(%B0, 5i32)");
}

test "SEG: β→let binds the argument exactly once (no duplication)" {
    const src = try probe_corpus.read(testing.allocator, "probes/cases", "seg_beta_let_no_duplication");
    defer testing.allocator.free(src);
    var b = try buildText("app", &.{.{ "app", src }});
    defer b.deinit();
    const stats = try segAll(&b);
    try testing.expect(stats.beta >= 1);
    // The Copy/discardable argument is materialized once as a let; the
    // body then reads it from the binder — never `call(idf, …)` twice.
    try expectFuncBody(&b, "app.dup", "fn (B0: i32) => let B1: i32 = call(fnref F0, %B0) in add.i32(%B1, %B1)");
}

test "SEG: β is refused for an effectful body and for a non-Copy argument" {
    const src = try probe_corpus.read(testing.allocator, "probes/cases", "seg_beta_refused_effectful");
    defer testing.allocator.free(src);
    var b = try buildText("app", &.{.{ "app", src }});
    defer b.deinit();
    _ = try segAll(&b);
    // The λ body calls a host binding: not cleanup-free / not observable-
    // effect-free, so no β and the call site keeps its `fn_ref`.
    const text = try funcText(&b, "app.eff");
    try testing.expect(std.mem.indexOf(u8, text, "call(fnref") != null);
}

test "SEG: β admits an effectful argument (docs/effects.md §10.4)" {
    const src = try probe_corpus.read(testing.allocator, "probes", "effectful_beta");
    defer testing.allocator.free(src);
    var b = try buildText("app", &.{.{ "app", src }});
    defer b.deinit();
    const stats = try segAll(&b);
    try testing.expect(stats.beta >= 4);
    // The argument is evaluated once and read from the binder.
    const doubled = try funcText(&b, "app.doubled");
    try testing.expect(std.mem.startsWith(u8, doubled, "fn () => let "));
    try testing.expect(std.mem.indexOf(u8, doubled, "call(") != null);
    // LTR: the first argument's effect is emitted before the second's.
    // A swap (or a used-once forwarding that moved the first init after
    // the second) would invert these positions.
    const ordered = try funcText(&b, "app.ordered");
    const first = std.mem.indexOf(u8, ordered, "1i32") orelse return error.TestUnexpectedResult;
    const second = std.mem.indexOf(u8, ordered, "2i32") orelse return error.TestUnexpectedResult;
    try testing.expect(first < second);
}

test "SEG: an effectful β argument keeps its let (no drop / forwarding)" {
    const src = try probe_corpus.read(testing.allocator, "probes", "effectful_beta");
    defer testing.allocator.free(src);
    var b = try buildText("app", &.{.{ "app", src }});
    defer b.deinit();
    _ = try segAll(&b);
    // The parameter is never read, but the init's effect is observable —
    // dead-let must refuse rather than delete the call.
    const unused = try funcText(&b, "app.unused");
    try testing.expect(std.mem.startsWith(u8, unused, "fn () => let "));
    try testing.expect(std.mem.indexOf(u8, unused, "call(") != null);
    // The parameter is read once, but forwarding the init to its use point
    // would move the effect off the argument position — the init must stay
    // the let it was.
    const once = try funcText(&b, "app.once");
    try testing.expect(std.mem.startsWith(u8, once, "fn () => let "));
}

test "SEG: an effectful β clone binds fresh binders (scope mapping)" {
    const src = try probe_corpus.read(testing.allocator, "probes", "effectful_beta");
    defer testing.allocator.free(src);
    var b = try buildText("app", &.{.{ "app", src }});
    defer b.deinit();
    _ = try segAll(&b);
    const pr = &b.built.program;
    var lam_rec: ?hir.FuncRecord = null;
    for (b.built.funcs.items) |f| {
        if (f.kind == .lambda and std.mem.startsWith(u8, f.name, "app.doubled")) {
            lam_rec = f;
            break;
        }
    }
    const lam = lam_rec orelse return error.TestUnexpectedResult;
    const lam_param = pr.params(pr.regionsOf(lam.root)[0])[0];
    const dbl = try findFunc(&b, "app.doubled");
    // A function record's root is its (zero-param) thunk; its region root
    // is the body, which β turned into the outermost let.
    const dbl_body = pr.region(pr.regionsOf(dbl.root)[0]).root;
    const let_param = pr.params(pr.regionsOf(dbl_body)[0])[0];
    // The λ parameter and the call-site let binder are distinct identities.
    try testing.expect(lam_param != let_param);
    // The cloned body reads the call-site binder, never the λ binder.
    const body = pr.region(pr.regionsOf(dbl_body)[0]).root;
    var work = std.ArrayList(hir.ExprId).empty;
    defer work.deinit(testing.allocator);
    try work.append(testing.allocator, body);
    var saw_local = false;
    while (work.pop()) |cur| {
        const n = pr.node(cur);
        if (std.mem.eql(u8, hir.registry.get(n.op).name, "local")) {
            saw_local = true;
            try testing.expectEqual(let_param, n.payload.binder);
        }
        for (pr.operands(cur)) |op| try work.append(testing.allocator, op);
        for (pr.regionsOf(cur)) |r| try work.append(testing.allocator, pr.region(r).root);
    }
    try testing.expect(saw_local);
}

test "SEG: a full-expression boundary on a β argument refuses the reduction" {
    const src = try probe_corpus.read(testing.allocator, "probes", "effectful_beta");
    defer testing.allocator.free(src);
    var b = try buildText("app", &.{.{ "app", src }});
    defer b.deinit();
    const f = try findFunc(&b, "app.doubled");
    // `doubled`'s body (the root of its thunk region) is the
    // immediately-invoked call; operand 1 is its argument.
    const outer = b.built.program.region(b.built.program.regionsOf(f.root)[0]).root;
    const call = try findNode(&b, outer, "call") orelse return error.TestUnexpectedResult;
    const arg = b.built.program.operands(call)[1];
    b.built.program.exprs.items[arg].full_expr = 1;
    // Run the pass alone (the §2.4 re-validation is what would reject the
    // corrupted annotation first, and this test pins the rule's own gate).
    _ = try hir_seg.optimize(b.arena.allocator(), b.built, .{ .graph = b.graph });
    const after = b.built.program.region(b.built.program.regionsOf(f.root)[0]).root;
    const after_name = hir.registry.get(b.built.program.node(after).op).name;
    try testing.expect(std.mem.eql(u8, after_name, "call"));
}

test "SEG: β preserves effectful argument order (SEG-on == SEG-off)" {
    const src = try probe_corpus.read(testing.allocator, "probes", "effectful_beta");
    defer testing.allocator.free(src);
    const off = try capture(src, false);
    defer testing.allocator.free(off);
    const on = try capture(src, true);
    defer testing.allocator.free(on);
    try testing.expectEqualStrings(off, on);
    // Non-vacuous: the two effectful arguments print in source order.
    try testing.expect(std.mem.indexOf(u8, on, "1\n2\n21") != null);
}

test "SEG: may-trap ops never enter an island (div is left to the runtime)" {
    const src = try probe_corpus.read(testing.allocator, "probes/cases", "seg_div_left_to_runtime");
    defer testing.allocator.free(src);
    var b = try buildText("app", &.{.{ "app", src }});
    defer b.deinit();
    _ = try segAll(&b);
    try expectFuncBody(&b, "app.q", "fn (B0: i32, B1: i32) => div.i32(%B0, %B1)");
    // `10 / 2` is not total by the declared effect row, so it is neither
    // folded nor deleted even though the binding is unused.
    try expectFuncBody(&b, "app.keep", "fn () => let B0: i32 = div.i32(10i32, 2i32) in 0i32");
}

test "SEG: float algebra is not applied (only integer identities + folding)" {
    const src = try probe_corpus.read(testing.allocator, "probes/cases", "seg_float_algebra_not_applied");
    defer testing.allocator.free(src);
    var b = try buildText("app", &.{.{ "app", src }});
    defer b.deinit();
    _ = try segAll(&b);
    try expectFuncBody(&b, "app.fadd", "fn (B0: f32) => add.f32(%B0, 0f32)");
    try expectFuncBody(&b, "app.fmul", "fn (B0: f32) => mul.f32(%B0, 1f32)");
    try expectFuncBody(&b, "app.fzero", "fn (B0: f32) => mul.f32(%B0, 0f32)");
}

test "SEG: constant if / and / or select the taken island branch" {
    const src = try probe_corpus.read(testing.allocator, "probes/cases", "seg_constant_if_and_or");
    defer testing.allocator.free(src);
    var b = try buildText("app", &.{.{ "app", src }});
    defer b.deinit();
    _ = try segAll(&b);
    try expectFuncBody(&b, "app.pick", "fn () => 10i32");
    try expectFuncBody(&b, "app.shorty", "fn () => true");
}

test "SEG: a trapping untaken branch keeps the branch node out of an island" {
    const src = try probe_corpus.read(testing.allocator, "probes/cases", "seg_trapping_untaken_branch");
    defer testing.allocator.free(src);
    var b = try buildText("app", &.{.{ "app", src }});
    defer b.deinit();
    _ = try segAll(&b);
    // The `div` in the untaken branch makes the whole branch non-total, so
    // the `if` is not an island and stays in place.
    const text = try funcText(&b, "app.guarded");
    try testing.expect(std.mem.indexOf(u8, text, "if") != null);
}

test "SEG: known-variant match reduces to the arm body (single / nullary / multi payload)" {
    const src = try probe_corpus.read(testing.allocator, "probes/cases", "seg_known_variant_match");
    defer testing.allocator.free(src);
    var b = try buildText("app", &.{.{ "app", src }});
    defer b.deinit();
    const stats = try segAll(&b);
    try testing.expect(stats.matches >= 3);
    try expectFuncBody(&b, "app.single", "fn (B0: i32) => add.i32(%B0, 1i32)");
    try expectFuncBody(&b, "app.nullary", "fn () => 2i32");
    try expectFuncBody(&b, "app.multi", "fn (B0: i32, B1: i32) => sub.i32(%B0, %B1)");
}

test "SEG: known-variant match with a wildcard / catch-all payload drops the value" {
    const src = try probe_corpus.read(testing.allocator, "probes/cases", "seg_known_variant_match_wildcard");
    defer testing.allocator.free(src);
    var b = try buildText("app", &.{.{ "app", src }});
    defer b.deinit();
    const stats = try segAll(&b);
    try testing.expect(stats.matches >= 2);
    try expectFuncBody(&b, "app.wild", "fn (B0: i32) => 7i32");
    try expectFuncBody(&b, "app.catchall", "fn (B0: i32) => 7i32");
}

test "SEG: a consuming or borrowed scrutinee keeps the match out of an island" {
    const src = try probe_corpus.read(testing.allocator, "probes/cases", "seg_consuming_borrowed_scrutinee");
    defer testing.allocator.free(src);
    var b = try buildText("app", &.{.{ "app", src }});
    defer b.deinit();
    // Admission itself refuses the match: the scrutinee is a `move` /
    // borrowed non-Copy value, so `isSegSafe(match)` is false before any
    // rewriting (not merely "no rule happened to fire").
    var an = try analysisOf(&b);
    const take_m = (try findNode(&b, (try findFunc(&b, "app.take")).root, "match")) orelse return error.TestUnexpectedResult;
    const inspect_m = (try findNode(&b, (try findFunc(&b, "app.inspect")).root, "match")) orelse return error.TestUnexpectedResult;
    try testing.expect(!try an.isSegSafe(take_m));
    try testing.expect(!try an.isSegSafe(inspect_m));
    const stats = try segAll(&b);
    // Non-vacuous: the match node survives rather than the rule never
    // seeing one.
    try testing.expectEqual(@as(usize, 0), stats.matches);
    try testing.expect(try funcHasNode(&b, "app.take", "match"));
    try testing.expect(try funcHasNode(&b, "app.inspect", "match"));
}

test "SEG: an effectful (even untaken) arm keeps a known-variant match intact" {
    const src = try probe_corpus.read(testing.allocator, "probes/cases", "seg_effectful_arm_match");
    defer testing.allocator.free(src);
    var b = try buildText("app", &.{.{ "app", src }});
    defer b.deinit();
    const stats = try segAll(&b);
    // The arm's host call makes the match summary non-pure; its region root
    // is not an island member, so the whole match stays in place.
    try testing.expectEqual(@as(usize, 0), stats.matches);
    try testing.expect(try funcHasNode(&b, "app.f", "match"));
}

test "SEG: a nested payload pattern refuses the known-variant reduction" {
    const src = try probe_corpus.read(testing.allocator, "probes/cases", "seg_nested_payload_pattern");
    defer testing.allocator.free(src);
    var b = try buildText("app", &.{.{ "app", src }});
    defer b.deinit();
    const stats = try segAll(&b);
    // The outer tag does not discharge the nested `struct_` pattern, and
    // the rule refuses rather than mis-binding the payload.
    try testing.expectEqual(@as(usize, 0), stats.matches);
    try testing.expect(try funcHasNode(&b, "app.f", "match"));
}

/// One analysis/rewrite round only (no fixpoint), so a rule's immediate
/// output survives long enough to be inspected before later rounds
/// simplify it away.
fn segOnce(b: *Built) !hir_seg.Stats {
    const stats = try hir_seg.optimize(b.arena.allocator(), b.built, .{ .graph = b.graph, .max_iterations = 1 });
    try revalidateRewritten(b);
    return stats;
}

/// First `name`-op node in `root`'s subtree (used by the malformed-HIR
/// negatives: build well-formed HIR, then corrupt exactly one field).
fn findNode(b: *Built, root: hir.ExprId, name: []const u8) !?hir.ExprId {
    var work = std.ArrayListUnmanaged(hir.ExprId).empty;
    defer work.deinit(testing.allocator);
    try work.append(testing.allocator, root);
    while (work.pop()) |id| {
        const pr = &b.built.program;
        if (std.mem.eql(u8, hir.registry.get(pr.node(id).op).name, name)) return id;
        for (pr.operands(id)) |op| try work.append(testing.allocator, op);
        for (pr.regionsOf(id)) |r| try work.append(testing.allocator, pr.region(r).root);
    }
    return null;
}

/// Whether function `func` still contains a `name`-op node — the
/// non-vacuous form of "the rule did not fire" (the printer cannot
/// serialize a `move`/host-call match, so text search is not available).
fn funcHasNode(b: *Built, func: []const u8, name: []const u8) !bool {
    const f = try findFunc(b, func);
    return (try findNode(b, f.root, name)) != null;
}

test "SEG: known-variant match splices payload lets in constructor order (one round)" {
    const src = try probe_corpus.read(testing.allocator, "probes/cases", "seg_pair_match");
    defer testing.allocator.free(src);
    var b = try buildText("app", &.{.{ "app", src }});
    defer b.deinit();
    const stats = try segOnce(&b);
    try testing.expectEqual(@as(usize, 1), stats.matches);
    // One `let` per payload leaf, outermost = first operand, so the
    // subtraction reads the payloads in constructor order (a swap would
    // print sub.i32(%B3, %B2)).
    try expectFuncBody(&b, "app.f", "fn (B0: i32, B1: i32) => let B2: i32 = %B0 in let B3: i32 = %B1 in sub.i32(%B2, %B3)");
}

test "SEG: an out-of-range constructor tag refuses the reduction" {
    const src = try probe_corpus.read(testing.allocator, "probes/cases", "seg_value_match");
    defer testing.allocator.free(src);
    var b = try buildText("app", &.{.{ "app", src }});
    defer b.deinit();
    const f = try findFunc(&b, "app.f");
    const vm = try findNode(&b, f.root, "variant_make") orelse return error.TestUnexpectedResult;
    // The checker cannot emit this tag; the rule must not bind a bogus
    // payload or trust the union declaration blindly.
    b.built.program.exprs.items[vm].payload.tag = 99;
    const stats = try segAll(&b);
    try testing.expectEqual(@as(usize, 0), stats.matches);
    try testing.expect(try funcHasNode(&b, "app.f", "match"));
}

test "SEG: an out-of-range arm pattern tag refuses the reduction" {
    const src = try probe_corpus.read(testing.allocator, "probes/cases", "seg_value_match");
    defer testing.allocator.free(src);
    var b = try buildText("app", &.{.{ "app", src }});
    defer b.deinit();
    const f = try findFunc(&b, "app.f");
    const m = try findNode(&b, f.root, "match") orelse return error.TestUnexpectedResult;
    const rid = b.built.program.regionsOf(m)[0];
    const pid = b.built.program.region(rid).pattern.?;
    b.built.program.patterns.items[pid].variant.tag = 99;
    const stats = try segAll(&b);
    try testing.expectEqual(@as(usize, 0), stats.matches);
    try testing.expect(try funcHasNode(&b, "app.f", "match"));
}

test "SEG: a declaration/constructor arity mismatch refuses the reduction" {
    const src = try probe_corpus.read(testing.allocator, "probes/cases", "seg_pair_match");
    defer testing.allocator.free(src);
    var b = try buildText("app", &.{.{ "app", src }});
    defer b.deinit();
    const f = try findFunc(&b, "app.f");
    const vm = try findNode(&b, f.root, "variant_make") orelse return error.TestUnexpectedResult;
    const named = switch (b.built.program.node(vm).ty) {
        .named => |n| n,
        else => return error.TestUnexpectedResult,
    };
    const ud = &b.built.types[named.id].union_;
    // Declare variant 0 payload-less while the constructor still supplies
    // operands; the rule must reject the mismatch, not drop the payloads.
    ud.variants[0].payloads = ud.variants[0].payloads[0..0];
    const stats = try segAll(&b);
    try testing.expectEqual(@as(usize, 0), stats.matches);
    try testing.expect(try funcHasNode(&b, "app.f", "match"));
}

test "SEG: a payload-pattern arity mismatch refuses the reduction" {
    const src = try probe_corpus.read(testing.allocator, "probes/cases", "seg_pair_match");
    defer testing.allocator.free(src);
    var b = try buildText("app", &.{.{ "app", src }});
    defer b.deinit();
    const f = try findFunc(&b, "app.f");
    const m = try findNode(&b, f.root, "match") orelse return error.TestUnexpectedResult;
    const rid = b.built.program.regionsOf(m)[0];
    const pid = b.built.program.region(rid).pattern.?;
    // The arm's tuple leaf now has one element for a two-payload
    // constructor; the rule must reject rather than bind one payload as a
    // pair.
    const payload = b.built.program.patterns.items[pid].variant.payload orelse return error.TestUnexpectedResult;
    const elems = b.built.program.patterns.items[payload].tuple;
    b.built.program.patterns.items[payload].tuple = elems[0..1];
    // The corrupted pattern no longer has the region's leaf/param
    // bijection, so `hir.validate` would reject it; run the pass alone to
    // pin the rule's own guard.
    const stats = try hir_seg.optimize(b.arena.allocator(), b.built, .{ .graph = b.graph });
    try testing.expectEqual(@as(usize, 0), stats.matches);
    try testing.expect(try funcHasNode(&b, "app.f", "match"));
}

test "SEG: the pass is a fixpoint (second run rewrites nothing)" {
    const src = try probe_corpus.read(testing.allocator, "probes/cases", "seg_fixpoint_corpus");
    defer testing.allocator.free(src);
    var b = try buildText("app", &.{.{ "app", src }});
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
    const src = try probe_corpus.read(testing.allocator, "probes/cases", "seg_beta_let_no_duplication");
    defer testing.allocator.free(src);
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
    const src = try probe_corpus.read(testing.allocator, "probes/cases", "seg_beta_let_no_duplication");
    defer testing.allocator.free(src);
    var b = try buildText("app", &.{.{ "app", src }});
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
    const src = try probe_corpus.read(testing.allocator, "probes/cases", "seg_borrowed_view");
    defer testing.allocator.free(src);
    var b = try buildText("app", &.{.{ "app", src }});
    defer b.deinit();
    _ = try segAll(&b);
    // The `local` reads a `.borrow`-mode binder, so `isSegSafe` fails:
    // neither `x + 0` nor the unused binding is rewritten.
    try expectFuncBody(&b, "app.f", "fn (B0: i32 @borrow) => let B1: i32 = add.i32(%B0, 0i32) in 7i32");
}

test "SEG: optimized HIR prints and parses back to the same text" {
    const src = try probe_corpus.read(testing.allocator, "probes/cases", "seg_beta_let_no_duplication");
    defer testing.allocator.free(src);
    var b = try buildText("app", &.{.{ "app", src }});
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
    const src = try probe_corpus.read(testing.allocator, "probes/cases", "seg_off_by_default_air");
    defer testing.allocator.free(src);
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
    var l = try support.loadOpts(text, false, seg, false);
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
        .panic => return error.TestUnexpectedResult,
    }
    return testing.allocator.dupe(u8, state.buffer[0..state.len]);
}

test "SEG: SEG-on and SEG-off execute identically (β, let, algebra, if)" {
    const src = try probe_corpus.read(testing.allocator, "probes/cases", "seg_exec_identical");
    defer testing.allocator.free(src);
    const off = try capture(src, false);
    defer testing.allocator.free(off);
    const on = try capture(src, true);
    defer testing.allocator.free(on);
    try testing.expectEqualStrings(off, on);
    // Non-vacuous: the program prints.
    try testing.expect(std.mem.indexOf(u8, on, "12") != null);
}

test "SEG: SEG-on and SEG-off execute a known-variant match identically" {
    const src = try probe_corpus.read(testing.allocator, "probes/cases", "seg_match_exec_identical");
    defer testing.allocator.free(src);
    const off = try capture(src, false);
    defer testing.allocator.free(off);
    const on = try capture(src, true);
    defer testing.allocator.free(on);
    try testing.expectEqualStrings(off, on);
    try testing.expect(std.mem.indexOf(u8, on, "42") != null);
}

// ---------------------------------------------------------------------------
// Corpus: every example / probe compiles through the SEG seam
// ---------------------------------------------------------------------------

/// One corpus execution's observable outcome for the SEG-on/off
/// differential: the captured output, how the run ended, and the panic
/// message / run error name. Output printed *before* a panic or run
/// error is part of the observable result (hir.md §10.3).
const Term = struct {
    out: []u8,
    end: enum { normal, panic, failed },
    /// Panic message, or the run error name; empty on normal completion.
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

/// Run one corpus program to completion, capturing output, termination,
/// and the panic / error detail. `capture`'s variant that does not fail
/// the test on a panic — the differential only requires SEG-on and
/// SEG-off agree.
///
/// Each run uses its own arena: `VmHeap.deinit` frees only the
/// provenance registry, so Copy heap objects (strings, list cells) can
/// still be live when a run ends, and the leak checker is not part of
/// this semantic differential. The harness owns that arena and releases
/// it whole; it does not verify runtime leak-freedom.
fn captureTerm(text: []const u8, seg: bool) !Term {
    var state = CaptureAdapter{};
    var l = try support.loadOpts(text, false, seg, false);
    defer l.deinit();
    // The corpus imports std modules, so the root image alone cannot run:
    // build the whole-program artifact bundle and resolve `import`s through
    // its loader (the load-tests' pattern).
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

/// SEG-on and SEG-off interpretation must agree verbatim — output,
/// termination, and panic message (hir.md §10.3). `expect_panic` pins the
/// intended termination so a coincidentally identical failure cannot pass
/// as coverage.
fn corpusDiff(dir: []const u8, spec: []const u8, expect_panic: bool) !void {
    const path = try probe_corpus.path(testing.allocator, dir, spec);
    defer testing.allocator.free(path);
    const text = probe_corpus.read(testing.allocator, dir, spec) catch |err| {
        std.debug.print("SEG corpus: cannot read {s} ({s})\n", .{ path, @errorName(err) });
        return error.TestUnexpectedResult;
    };
    defer testing.allocator.free(text);
    var off = try captureTerm(text, false);
    defer off.deinit();
    var on = try captureTerm(text, true);
    defer on.deinit();
    // The differential must actually execute the program. A run error, or
    // the capture adapter's overflow sentinel, would make a matching
    // failure vacuous, so surface them.
    if (off.end == .failed) {
        std.debug.print("SEG corpus: {s} did not run with SEG off: {s} (output {d} bytes)\n", .{ path, off.detail, off.out.len });
        return error.TestUnexpectedResult;
    }
    if (off.end == .panic and std.mem.eql(u8, off.detail, "capture buffer overflow")) {
        std.debug.print("SEG corpus: {s} overflowed the capture buffer\n", .{path});
        return error.TestUnexpectedResult;
    }
    const End = @TypeOf(off.end);
    const want: End = if (expect_panic) .panic else .normal;
    if (off.end != want or on.end != want) {
        std.debug.print("SEG corpus: {s} expected {s} termination, got off={s} {s} / on={s} {s}\n", .{ path, @tagName(want), @tagName(off.end), off.detail, @tagName(on.end), on.detail });
        return error.TestUnexpectedResult;
    }
    if (!Term.eql(off, on)) {
        std.debug.print("SEG corpus: {s} SEG-on/off interpretation differs (off={s} {s}, on={s} {s})\n", .{ path, @tagName(off.end), off.detail, @tagName(on.end), on.detail });
        return error.TestUnexpectedResult;
    }
}

fn corpusSeg(dir: []const u8, spec: []const u8) !void {
    const path = try probe_corpus.path(testing.allocator, dir, spec);
    defer testing.allocator.free(path);
    const text = probe_corpus.read(testing.allocator, dir, spec) catch |err| {
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

test "SEG corpus — examples/*.st compile+round-trip and SEG-on/off agree" {
    var corpus = try probe_corpus.list(testing.allocator, "examples");
    defer corpus.deinit();
    for (corpus.names) |spec| {
        try corpusSeg("examples", spec);
        try corpusDiff("examples", spec, false);
    }
}

test "SEG corpus — probes/*.st compile+round-trip and SEG-on/off agree" {
    var corpus = try probe_corpus.list(testing.allocator, "probes");
    defer corpus.deinit();
    for (corpus.names) |spec| {
        try corpusSeg("probes", spec);
        try corpusDiff("probes", spec, probe_corpus.panics(spec));
    }
}
