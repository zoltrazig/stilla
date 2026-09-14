//! HIR SEG black-box suite — cross-module tests of the M2a SEG pass
//! (docs/hir.md §8/§11 M2a). White-box rule/cost tests live in
//! `passes/hir_seg.zig`; this file builds real modules through the
//! checker + HIR builder, runs the pass, re-validates structure and
//! effects, and checks the observable rule set, the negative cases, the
//! corpus (compiles through the seam with SEG on), the four
//! `--simplify` × `--seg` combinations interpreting every corpus program
//! identically, and the corpus-level compile-time / round budget.
//!
//! Wired into root.zig's test block; run via `zig build test`.

const std = @import("std");
const moduleinfo = @import("moduleinfo.zig");
const checker = @import("passes/checker.zig");
const cfg = @import("cfg.zig");
const hir = @import("hir.zig");
const hir_build = @import("passes/hir_build.zig");
const hir_effects = @import("passes/hir_effects.zig");
const effects = @import("effects.zig");
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
    return revalidateRewrittenWith(b, &.{});
}

/// `revalidateRewritten` under an explicit host-declaration environment
/// (docs/effects.md §13), so a rewrite run and its re-validation share
/// one effect environment (the `simplifyAllWith` pattern).
fn revalidateRewrittenWith(b: *Built, host_decls: []const effects.HostDecl) !void {
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
    var an = try hir_effects.Analysis.init(b.arena.allocator(), b.built, .{ .graph = b.graph, .host_decls = host_decls });
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

/// `segAll` under an explicit host-declaration environment.
fn segAllWith(b: *Built, host_decls: []const effects.HostDecl) !hir_seg.Stats {
    const stats = try hir_seg.optimize(b.arena.allocator(), b.built, .{ .graph = b.graph, .host_decls = host_decls });
    try revalidateRewrittenWith(b, host_decls);
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

fn findFuncId(b: *Built, name: []const u8) !hir.FuncId {
    for (b.built.funcs.items, 0..) |f, i| {
        if (std.mem.eql(u8, f.name, name)) return @intCast(i);
    }
    return error.TestUnexpectedResult;
}

/// The function indices named by every `fn_ref` in `func`'s subtree (a
/// host `fn_ref` is skipped — it has no `FuncId`). The η fixtures give
/// each wrapper value exactly one `fn_ref`, so the sole entry is the
/// wrapper's current target.
fn fnRefTargets(b: *Built, func: []const u8, out: *std.ArrayListUnmanaged(hir.FuncId)) !void {
    const f = try findFunc(b, func);
    const pr = &b.built.program;
    var work = std.ArrayListUnmanaged(hir.ExprId).empty;
    defer work.deinit(testing.allocator);
    try work.append(testing.allocator, f.root);
    while (work.pop()) |id| {
        const n = pr.node(id);
        if (std.mem.eql(u8, hir.registry.get(n.op).name, "fn_ref")) {
            switch (n.payload.func) {
                .func => |fid| try out.append(testing.allocator, fid),
                .host => {},
            }
        }
        for (pr.operands(id)) |op| try work.append(testing.allocator, op);
        for (pr.regionsOf(id)) |r| try work.append(testing.allocator, pr.region(r).root);
    }
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

/// The initializer of the first single-parameter `let` in `name`'s body —
/// the shape `ruleLet` matches. The source-level fixtures put that `let` at
/// the body root, so the first `let` found is it.
fn letInit(b: *Built, name: []const u8) !hir.ExprId {
    const f = try findFunc(b, name);
    const let = (try findNode(b, f.root, "let")) orelse return error.TestUnexpectedResult;
    return b.built.program.operands(let)[0];
}

test "SEG: a source-level let folds across the full-expression boundary (hir.md §8.7)" {
    const src = try probe_corpus.read(testing.allocator, "probes", "seg");
    defer testing.allocator.free(src);
    var b = try buildText("app", &.{.{ "app", src }});
    defer b.deinit();
    const pr = &b.built.program;

    // The contract facts the three folds are admitted by, read off the
    // derived queries (the engine's `check` / `checkCleanup` consume
    // exactly these) before any rewrite. A source-level initializer is its
    // own full expression, so each init's FE differs from its `let`'s.
    var an = try analysisOf(&b);
    const dead_init = try letInit(&b, "app.unused_let");
    const forward_init = try letInit(&b, "app.forward_once");
    const atom_init = try letInit(&b, "app.atom_twice");
    try testing.expect(try an.isDiscardable(dead_init));
    try testing.expect(try an.isSegSafe(forward_init) and try an.cleanupFree(forward_init));
    try testing.expect(try an.isDuplicable(atom_init));
    for ([_]struct { []const u8, hir.ExprId }{
        .{ "app.unused_let", dead_init },
        .{ "app.forward_once", forward_init },
        .{ "app.atom_twice", atom_init },
    }) |pair| {
        // The initializer is its own full expression: its FE differs from
        // the `let`'s (the region body's).
        const let = (try findNode(&b, (try findFunc(&b, pair[0])).root, "let")) orelse return error.TestUnexpectedResult;
        try testing.expect(pr.node(pair[1]).full_expr != pr.node(let).full_expr);
    }
    // The negative side of the same queries: borrowed view (ownership
    // gate), Unique constructor (not Copy), may-trap initializer and the
    // effectful call (not an island member — `isSegSafe` is its semantic
    // content; a `call` over a `fn_ref` also has no encoding).
    try testing.expect(!try an.isDuplicable(try letInit(&b, "app.borrowed_kept")));
    try testing.expect(!try an.isDuplicable(try letInit(&b, "app.unique_kept")));
    try testing.expect(!try an.isDiscardable(try letInit(&b, "app.trapping_kept")));
    try testing.expect(!try an.isSegSafe(try letInit(&b, "app.observable_kept")));
    // The implicit `any` coercion is a type difference, not an effect fact.
    const coerced_let = (try findNode(&b, (try findFunc(&b, "app.coerced_kept")).root, "let")) orelse return error.TestUnexpectedResult;
    try testing.expect(!pr.node(pr.operands(coerced_let)[0]).ty.eql(pr.binder(pr.params(pr.regionsOf(coerced_let)[0])[0]).ty));

    const stats = try segAll(&b);
    // The three contract positives: the discardable initializer is
    // dropped, the island-member initializer moves to its single use, and
    // the trivial atom is copied to both uses.
    try expectFuncBody(&b, "app.unused_let", "fn (B0: i32) => %B0");
    try expectFuncBody(&b, "app.forward_once", "fn (B0: i32) => mul.i32(add.i32(%B0, 1i32), 2i32)");
    try expectFuncBody(&b, "app.atom_twice", "fn (B0: i32) => add.i32(%B0, %B0)");
    try testing.expect(stats.lets >= 3);
    // The refused shapes keep their `let`: a borrowed-view atom, a
    // may-trap initializer, an effectful call, an implicit coercion and a
    // Unique constructor result. (`probes/any.st` / `probes/calls.st` pin
    // the other two match-layer refusals: a binder read from a `move` slot
    // and an implicit `any` coercion — both crashed lowering before the
    // guards, and every probe is compiled and run by the corpus suite.)
    try expectFuncBody(&b, "app.borrowed_kept", "fn (B0: i32 @borrow) => let B1: i32 = %B0 in add.i32(%B1, %B1)");
    try expectFuncBody(&b, "app.trapping_kept", "fn (B0: i32) => let B1: i32 = div.i32(10i32, %B0) in add.i32(%B1, 1i32)");
    try expectFuncBody(&b, "app.coerced_kept", "fn (B0: i32) => let B1: any = %B0 in any_cast(%B1): i32");
    // `observable_kept` keeps its `let`: the call prints. The refs
    // dictionary is per-print, and this body names one target, so it is F0.
    try expectFuncBody(&b, "app.observable_kept", "fn (B0: i32) => let B1: i32 = call(fnref F0, %B0) in add.i32(%B1, 1i32)");
    try testing.expect(try funcHasNode(&b, "app.unique_kept", "let"));

    // `maps_full_expr`: the forwarded initializer subtree was re-stamped
    // onto the destination, so the rewritten body is one full expression
    // again (a stale init-boundary id would break every enclosing gate).
    const fwd_root = pr.region(pr.regionsOf((try findFunc(&b, "app.forward_once")).root)[0]).root;
    const fwd_fe = pr.node(fwd_root).full_expr;
    var work = std.ArrayList(hir.ExprId).empty;
    defer work.deinit(testing.allocator);
    try work.append(testing.allocator, fwd_root);
    while (work.pop()) |id| {
        try testing.expectEqual(fwd_fe, pr.node(id).full_expr);
        for (pr.operands(id)) |op| try work.append(testing.allocator, op);
        for (pr.regionsOf(id)) |r| try work.append(testing.allocator, pr.region(r).root);
    }
    // The atom copies are distinct nodes (HIR is a tree, §3.7) and both
    // carry the destination full expression.
    const atom_root = pr.region(pr.regionsOf((try findFunc(&b, "app.atom_twice")).root)[0]).root;
    const atom_ops = pr.operands(atom_root);
    try testing.expectEqual(@as(usize, 2), atom_ops.len);
    try testing.expect(atom_ops[0] != atom_ops[1]);
    try testing.expectEqual(pr.node(atom_root).full_expr, pr.node(atom_ops[0]).full_expr);
    try testing.expectEqual(pr.node(atom_root).full_expr, pr.node(atom_ops[1]).full_expr);
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

test "SEG: η-reduction redirects a λ wrapper to its fn_ref callee" {
    const src = try probe_corpus.read(testing.allocator, "probes", "eta");
    defer testing.allocator.free(src);
    var b = try buildText("eta", &.{.{ "eta", src }});
    defer b.deinit();
    const stats = try segAll(&b);
    try testing.expect(stats.etas >= 1);
    const identity_id = try findFuncId(&b, "eta.identity");

    // `via_lambda`'s wrapper value now names the member function directly.
    var targets = std.ArrayListUnmanaged(hir.FuncId).empty;
    defer targets.deinit(testing.allocator);
    try fnRefTargets(&b, "eta.via_lambda", &targets);
    try testing.expectEqual(@as(usize, 1), targets.items.len);
    try testing.expectEqual(identity_id, targets.items[0]);

    // `via_chain`'s outer wrapper resolves through the inner wrapper to
    // the same target in one call.
    var chain_targets = std.ArrayListUnmanaged(hir.FuncId).empty;
    defer chain_targets.deinit(testing.allocator);
    try fnRefTargets(&b, "eta.via_chain", &chain_targets);
    try testing.expectEqual(@as(usize, 1), chain_targets.items.len);
    try testing.expectEqual(identity_id, chain_targets.items[0]);

    // The λ record itself is untouched — the rewrite is a value redirect,
    // not a mutation of the hoisted function root (hir_lower's invariant).
    for (b.built.funcs.items) |f| {
        if (f.kind == .lambda and std.mem.startsWith(u8, f.name, "eta.via_lambda")) {
            try testing.expectEqualStrings("lambda", hir.registry.get(b.built.program.node(f.root).op).name);
        }
    }

    // A second run is a fixpoint: no further η (or any other) rewrite.
    const second = try segAll(&b);
    try testing.expectEqual(@as(usize, 0), second.etas);
    try testing.expectEqual(@as(usize, 0), second.beta + second.folds + second.algebra + second.lets + second.conds + second.matches);
}

test "SEG: η-reduction is refused for trap / non-fn_ref / swapped-argument wrappers" {
    const src = try probe_corpus.read(testing.allocator, "probes", "eta");
    defer testing.allocator.free(src);
    var b = try buildText("eta", &.{.{ "eta", src }});
    defer b.deinit();
    _ = try segAll(&b);
    // Each refused wrapper keeps its `fn_ref` pointing at the λ record
    // (never at the would-be callee). The trap case fails the totality
    // gate; the other two are structural (callee not a `fn_ref`; the
    // arguments are not the wrapper's own parameters in order).
    const refused = [_][]const u8{ "eta.via_boom", "eta.via_call", "eta.via_swap" };
    for (refused) |func| {
        var targets = std.ArrayListUnmanaged(hir.FuncId).empty;
        defer targets.deinit(testing.allocator);
        try fnRefTargets(&b, func, &targets);
        try testing.expectEqual(@as(usize, 1), targets.items.len);
        try testing.expectEqual(hir.FuncKind.lambda, b.built.funcs.items[targets.items[0]].kind);
    }
}

test "SEG: a wrapper/callee function-type mismatch refuses η" {
    const src = try probe_corpus.read(testing.allocator, "probes", "eta");
    defer testing.allocator.free(src);
    var b = try buildText("eta", &.{.{ "eta", src }});
    defer b.deinit();
    // Corrupt the wrapper value's function type; §8.5's "exact same fn
    // type" gate must then refuse even though the shape is right.
    const f = try findFunc(&b, "eta.via_lambda");
    const ref = (try findNode(&b, f.root, "fn_ref")) orelse return error.TestUnexpectedResult;
    b.built.program.exprs.items[ref].ty = .{ .primitive = .int32 };
    // The corrupted type would fail re-validation, so run the pass alone.
    _ = try hir_seg.optimize(b.arena.allocator(), b.built, .{ .graph = b.graph });
    var targets = std.ArrayListUnmanaged(hir.FuncId).empty;
    defer targets.deinit(testing.allocator);
    try fnRefTargets(&b, "eta.via_lambda", &targets);
    try testing.expectEqual(@as(usize, 1), targets.items.len);
    try testing.expectEqual(hir.FuncKind.lambda, b.built.funcs.items[targets.items[0]].kind);
}

test "SEG: a cross-module (access-chain) callee refuses η" {
    const src = try probe_corpus.read(testing.allocator, "probes", "eta");
    defer testing.allocator.free(src);
    var b = try buildText("eta", &.{.{ "eta", src }});
    defer b.deinit();
    // A λ wrapping `other.f` is the one shape where η would move a module
    // initialization from call time to value-creation time. The analysis
    // marks any callee carrying `access_hops` as `Top`, so the body loses
    // totality and the redirect is refused. Model the marker directly on
    // the wrapper body's callee (a cross-module fixture would read the
    // same gate).
    var wrapper: ?hir.ExprId = null;
    for (b.built.funcs.items) |fr| {
        if (fr.kind == .lambda and std.mem.startsWith(u8, fr.name, "eta.via_lambda")) {
            wrapper = fr.root;
            break;
        }
    }
    const lam = wrapper orelse return error.TestUnexpectedResult;
    const body = b.built.program.region(b.built.program.regionsOf(lam)[0]).root;
    const callee = b.built.program.operands(body)[0];
    const hop = [_]hir.AccessHop{.{ .module = 0, .name = "identity" }};
    b.built.program.exprs.items[callee].access_hops = &hop;
    // The corrupted chain would fail re-validation, so run the pass alone.
    _ = try hir_seg.optimize(b.arena.allocator(), b.built, .{ .graph = b.graph });
    var targets = std.ArrayListUnmanaged(hir.FuncId).empty;
    defer targets.deinit(testing.allocator);
    try fnRefTargets(&b, "eta.via_lambda", &targets);
    try testing.expectEqual(@as(usize, 1), targets.items.len);
    try testing.expectEqual(hir.FuncKind.lambda, b.built.funcs.items[targets.items[0]].kind);
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
    // A genuine new boundary: the literal `1` could collide with the call
    // site's real FE now that the builder assigns them.
    b.built.program.exprs.items[arg].full_expr = try b.built.program.addFullExpr();
    try testing.expect(b.built.program.node(arg).full_expr != b.built.program.node(call).full_expr);
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
    // The constant condition is decided inside the initializer's own full
    // expression; the enclosing source-level `let` then folds under the
    // §8.7 boundary contract: its initializer is an island member (Copy,
    // total, cleanup-free), so used-once forwarding moves it to the use
    // point and the `let` disappears.
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

test "SEG: struct projection folds field_get over struct_make (every index)" {
    const src = try probe_corpus.read(testing.allocator, "probes", "struct_projection");
    defer testing.allocator.free(src);
    var b = try buildText("app", &.{.{ "app", src }});
    defer b.deinit();
    const stats = try segAll(&b);
    // Non-vacuous: the three declaration-ordered reads (and the operand
    // expression) project, so at least four folds happened.
    try testing.expect(stats.projects >= 4);
    // Each field index projects its own operand, in declaration order.
    try expectFuncBody(&b, "app.project_first", "fn () => 10i32");
    try expectFuncBody(&b, "app.project_second", "fn () => 20i32");
    try expectFuncBody(&b, "app.project_third", "fn () => 30i32");
    // The projected operand keeps its own (non-constant) expression.
    try expectFuncBody(&b, "app.project_expr", "fn (B0: i32) => add.i32(%B0, 1i32)");
}

test "SEG: a non-constructor base refuses struct projection" {
    const src = try probe_corpus.read(testing.allocator, "probes", "struct_projection");
    defer testing.allocator.free(src);
    var b = try buildText("app", &.{.{ "app", src }});
    defer b.deinit();
    _ = try segAll(&b);
    // `t.b` reads a `let`/parameter binding, not a constructor: the
    // `field_get` survives (the printer cannot serialize it, so the
    // non-vacuous check is the node itself).
    try testing.expect(try funcHasNode(&b, "app.project_binding", "field_get"));
}

test "SEG: an out-of-range field index refuses struct projection" {
    const src = try probe_corpus.read(testing.allocator, "probes", "struct_projection");
    defer testing.allocator.free(src);
    var b = try buildText("app", &.{.{ "app", src }});
    defer b.deinit();
    const f = try findFunc(&b, "app.project_second");
    const fg = try findNode(&b, f.root, "field_get") orelse return error.TestUnexpectedResult;
    // The checker can never emit this index; the rule must not read past
    // the constructor's operand list.
    b.built.program.exprs.items[fg].payload.field = 99;
    // The corrupted index would fail re-validation, so run the pass alone.
    const stats = try hir_seg.optimize(b.arena.allocator(), b.built, .{ .graph = b.graph });
    try testing.expect(stats.projects >= 3); // the other reads still fold
    try testing.expect(try funcHasNode(&b, "app.project_second", "field_get"));
}

test "SEG: a struct literal crossing a full-expression boundary is not an island" {
    const src = try probe_corpus.read(testing.allocator, "probes", "struct_projection");
    defer testing.allocator.free(src);
    var b = try buildText("app", &.{.{ "app", src }});
    defer b.deinit();
    const pr = &b.built.program;
    const f = try findFunc(&b, "app.project_second");
    const fg = try findNode(&b, f.root, "field_get") orelse return error.TestUnexpectedResult;
    const sm = pr.operands(fg)[0];
    // Positive control: the read is an island member and projects.
    var an = try analysisOf(&b);
    try testing.expect(try an.isSegSafe(fg));
    // Move one constructor operand into a fresh boundary: the read now
    // spans two full expressions, so admission refuses and no rule fires.
    const operand = pr.operands(sm)[0];
    pr.exprs.items[operand].full_expr = try pr.addFullExpr();
    var an2 = try analysisOf(&b);
    try testing.expect(!try an2.isSegSafe(fg));
    const stats = try hir_seg.optimize(b.arena.allocator(), b.built, .{ .graph = b.graph });
    try testing.expect(stats.projects >= 3); // the other reads still fold
    try testing.expect(try funcHasNode(&b, "app.project_second", "field_get"));
}

// ---------------------------------------------------------------------------
// CSE-style sharing (hir.md §8.3)
// ---------------------------------------------------------------------------

test "SEG: CSE shares a duplicate pure island operand into a let" {
    const src = try probe_corpus.read(testing.allocator, "probes/cases", "seg_cse_share");
    defer testing.allocator.free(src);
    var b = try buildText("app", &.{.{ "app", src }});
    defer b.deinit();
    const stats = try segAll(&b);
    try testing.expect(stats.shares >= 1);
    // Two `mul(%B0, %B1)` operands become one `let`-bound evaluation.
    try expectFuncBody(&b, "app.mul_pair", "fn (B0: i32, B1: i32) => let B2: i32 = mul.i32(%B0, %B1) in add.i32(%B2, %B2)");
    try testing.expectEqual(@as(usize, 1), try countNodes(&b, "app.mul_pair", "mul.i32"));
    // Tree, not DAG (§3.7): the two parameter reads plus the two shared-binder
    // reads are four distinct `local` nodes.
    try testing.expectEqual(@as(usize, 4), try countNodes(&b, "app.mul_pair", "local"));
    // "合成 let 不得改变销毁注册": no registered owner is orphaned.
    try testing.expect(try cleanupOriginsReachable(&b));
}

test "SEG: CSE is refused for a non-duplicable operand and across a full expression" {
    const src = try probe_corpus.read(testing.allocator, "probes/cases", "seg_cse_refused");
    defer testing.allocator.free(src);
    var b = try buildText("app", &.{.{ "app", src }});
    defer b.deinit();
    // The duplicate `div` pair: `div.i32` may trap, so not total — neither
    // an island member nor `isDuplicable`.
    const f = try findFunc(&b, "app.div_pair");
    const div0 = try findNode(&b, f.root, "div.i32") orelse return error.TestUnexpectedResult;
    var an = try analysisOf(&b);
    try testing.expect(!(try an.isDuplicable(div0)));
    try testing.expect(!try an.isSegSafe(div0));
    // Two α-equivalent `mul`s in separate source-`let` initializers (each
    // its own full expression) are never operands of one node. Both
    // binders are read twice and their initializers are not trivial atoms,
    // so neither `let` folds either — the muls stay in their own FEs.
    const stats = try segAll(&b);
    try testing.expectEqual(@as(usize, 0), stats.shares);
    try testing.expectEqual(@as(usize, 2), try countNodes(&b, "app.div_pair", "div.i32"));
    try testing.expectEqual(@as(usize, 2), try countNodes(&b, "app.cross_fe", "mul.i32"));
}

test "SEG: CSE is refused for a Unique operand (not duplicable)" {
    const src = try probe_corpus.read(testing.allocator, "probes/cases", "seg_cse_unique");
    defer testing.allocator.free(src);
    var b = try buildText("app", &.{.{ "app", src }});
    defer b.deinit();
    // The inner `Token { value: v }` constructor result is Unique: Copy
    // fails, so `isDuplicable` is false and the two constructors stay.
    const f = try findFunc(&b, "app.f");
    const two_make = try findNode(&b, f.root, "struct_make") orelse return error.TestUnexpectedResult;
    const token_make = b.built.program.operands(two_make)[0];
    var an = try analysisOf(&b);
    try testing.expect(!(try an.isDuplicable(token_make)));
    const stats = try segAll(&b);
    try testing.expectEqual(@as(usize, 0), stats.shares);
    // Two `Token` constructors survive (plus the `Two` aggregate).
    try testing.expectEqual(@as(usize, 3), try countNodes(&b, "app.f", "struct_make"));
}

test "SEG: CSE is refused for an observable or Q-carrying host read" {
    const sensor = try probe_corpus.read(testing.allocator, "probes/cases", "seg_cse_host_sensor");
    defer testing.allocator.free(sensor);
    const app = try probe_corpus.read(testing.allocator, "probes/cases", "seg_cse_host_app");
    defer testing.allocator.free(app);
    const texts = [_]struct { []const u8, []const u8 }{
        .{ "sensor", sensor },
        .{ "app", app },
    };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const write_read = try effects.summaryOf(a, &.{.{ .resource = .{ .host = 1 }, .mode = .write }});
    const plain_read = try effects.summaryOf(a, &.{.{ .resource = .{ .host = 1 }, .mode = .read }});
    const q_read = effects.Summary{
        .accesses = plain_read.accesses,
        .may_trap = false,
        .may_diverge = false,
        .nondeterministic = true,
    };
    const cases = [_]effects.Summary{ write_read, q_read };
    for (cases) |summary| {
        var b = try buildText("app", &texts);
        defer b.deinit();
        const decls = [_]effects.HostDecl{
            .{ .key = "sensor.read", .summary = summary, .stilla_execution = .forbidden },
        };
        const f = try findFunc(&b, "app.f");
        const call0 = try findNode(&b, f.root, "call") orelse return error.TestUnexpectedResult;
        var an = try hir_effects.Analysis.init(b.arena.allocator(), b.built, .{ .graph = b.graph, .host_decls = &decls });
        try an.analyze();
        try testing.expect(!(try an.isDuplicable(call0)));
        const stats = try segAllWith(&b, &decls);
        try testing.expectEqual(@as(usize, 0), stats.shares);
        try testing.expectEqual(@as(usize, 2), try countNodes(&b, "app.f", "call"));
    }
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

/// Number of `name`-op nodes reachable in `func`'s body — the
/// non-vacuous form of "the shared subtree is evaluated once" (one copy
/// remains after CSE, two before).
fn countNodes(b: *Built, func: []const u8, name: []const u8) !usize {
    const f = try findFunc(b, func);
    const pr = &b.built.program;
    var count: usize = 0;
    var work = std.ArrayListUnmanaged(hir.ExprId).empty;
    defer work.deinit(testing.allocator);
    try work.append(testing.allocator, f.root);
    while (work.pop()) |id| {
        if (std.mem.eql(u8, hir.registry.get(pr.node(id).op).name, name)) count += 1;
        for (pr.operands(id)) |op| try work.append(testing.allocator, op);
        for (pr.regionsOf(id)) |r| try work.append(testing.allocator, pr.region(r).root);
    }
    return count;
}

/// Every registered cleanup owner is still reachable from a function body
/// or constant initializer. CSE's donors become unreachable, so this
/// pins the "合成 `let` 不得改变销毁注册" clause: no `CleanupToken` may name
/// an orphaned duplicate.
fn cleanupOriginsReachable(b: *Built) !bool {
    const pr = &b.built.program;
    var live = std.AutoHashMapUnmanaged(hir.ExprId, void).empty;
    defer live.deinit(testing.allocator);
    var work = std.ArrayListUnmanaged(hir.ExprId).empty;
    defer work.deinit(testing.allocator);
    for (b.built.funcs.items) |f| try work.append(testing.allocator, f.root);
    for (b.built.consts.items) |c| {
        if (c.init) |root| try work.append(testing.allocator, root);
    }
    while (work.pop()) |id| {
        if (live.contains(id)) continue;
        try live.put(testing.allocator, id, {});
        for (pr.operands(id)) |op| try work.append(testing.allocator, op);
        for (pr.regionsOf(id)) |r| try work.append(testing.allocator, pr.region(r).root);
    }
    for (pr.cleanup_tokens.items) |tk| {
        if (!live.contains(tk.origin_expr)) return false;
    }
    return true;
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
    try testing.expect(first.converged);
    try testing.expect(first.beta + first.folds + first.algebra + first.lets + first.conds + first.shares > 0);
    const after_first = try funcText(&b, "app.dup");
    const after_first_g = try funcText(&b, "app.g");
    const after_first_cse = try funcText(&b, "app.cse_pair");

    const second = try segAll(&b);
    try testing.expectEqual(@as(usize, 0), second.beta + second.folds + second.algebra + second.lets + second.conds + second.shares);
    try testing.expectEqualStrings(after_first, try funcText(&b, "app.dup"));
    try testing.expectEqualStrings(after_first_g, try funcText(&b, "app.g"));
    // The CSE binding is stable: ≥2 uses and a non-trivial init mean no
    // let rule undoes it.
    try testing.expectEqualStrings(after_first_cse, try funcText(&b, "app.cse_pair"));
}

test "SEG: a construct needing more than one round converges within the bound" {
    // Round 1 folds the constant `if` condition, overwriting the operand node
    // in place; the parent add's CSE pass then refuses the just-rewritten
    // (dirty) operand and defers to a fresh round. The pass must reach
    // quiescence rather than stop at the `max_iterations` bound (hir.md §8.2
    // bounded-round contract, `Stats.converged`).
    const src = try probe_corpus.read(testing.allocator, "probes/cases", "seg_multi_round");
    defer testing.allocator.free(src);
    var b = try buildText("app", &.{.{ "app", src }});
    defer b.deinit();
    const first = try segAll(&b);
    try testing.expect(first.iterations > 1);
    try testing.expect(first.converged);
    try testing.expectEqual(@as(usize, 1), first.conds);
    try testing.expectEqual(@as(usize, 1), first.shares);
    // The extra rounds paid off: the two α-equal `x * x` operands are now one
    // computation read from a synthesized `let`.
    try testing.expectEqual(@as(usize, 1), try countNodes(&b, "app.share_after_fold", "mul.i32"));
    const after = try funcText(&b, "app.share_after_fold");
    const second = try segAll(&b);
    try testing.expect(second.converged);
    try testing.expectEqual(@as(usize, 0), second.beta + second.folds + second.algebra + second.lets + second.conds + second.shares);
    try testing.expectEqualStrings(after, try funcText(&b, "app.share_after_fold"));
}

test "SEG: two fresh builds produce the same optimized text (deterministic)" {
    // One β fixture and one CSE fixture: a CSE rewrite must also be stable
    // across fresh builds (the `BinderMap` is never iterated, so it is).
    const cases = [_]struct { []const u8, []const u8 }{
        .{ "seg_beta_let_no_duplication", "app.dup" },
        .{ "seg_cse_share", "app.mul_pair" },
    };
    for (cases) |case| {
        const src = try probe_corpus.read(testing.allocator, "probes/cases", case[0]);
        defer testing.allocator.free(src);
        var b1 = try buildText("app", &.{.{ "app", src }});
        defer b1.deinit();
        _ = try segAll(&b1);
        var b2 = try buildText("app", &.{.{ "app", src }});
        defer b2.deinit();
        _ = try segAll(&b2);
        try testing.expectEqualStrings(try funcText(&b1, case[1]), try funcText(&b2, case[1]));
    }
}

// ---------------------------------------------------------------------------
// Whole-pipeline: enabling SEG rewrites the AIR; both the SEG-on and
// SEG-off forms validate and round-trip.
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

test "SEG: β maps every cloned body node onto the call site's full expression" {
    const src = try probe_corpus.read(testing.allocator, "probes/cases", "seg_beta_let_no_duplication");
    defer testing.allocator.free(src);
    var b = try buildText("app", &.{.{ "app", src }});
    defer b.deinit();
    _ = try segAll(&b);
    const pr = &b.built.program;
    const dup = try findFunc(&b, "app.dup");
    // The λ body is now the β-synthesized outer `let`; its own `full_expr`
    // is the call site's.
    const body = pr.region(pr.regionsOf(dup.root)[0]).root;
    const call_fe = pr.node(body).full_expr;
    // Every node of the cloned body (and the original argument, which
    // stays put as the let initializer) carries the call-site FE
    // (hir.md §8.4 `maps_full_expr`).
    var work = std.ArrayList(hir.ExprId).empty;
    defer work.deinit(testing.allocator);
    try work.append(testing.allocator, body);
    var saw_add = false;
    while (work.pop()) |cur| {
        const n = pr.node(cur);
        try testing.expectEqual(call_fe, n.full_expr);
        if (std.mem.eql(u8, hir.registry.get(n.op).name, "add.i32")) saw_add = true;
        for (pr.operands(cur)) |op| try work.append(testing.allocator, op);
        for (pr.regionsOf(cur)) |r| try work.append(testing.allocator, pr.region(r).root);
    }
    try testing.expect(saw_add);
}

test "SEG: a full-expression boundary inside an island refuses admission" {
    const src = try probe_corpus.read(testing.allocator, "probes/cases", "seg_constant_folding");
    defer testing.allocator.free(src);
    var b = try buildText("app", &.{.{ "app", src }});
    defer b.deinit();
    const pr = &b.built.program;
    const f = try findFunc(&b, "app.f");
    const body = pr.region(pr.regionsOf(f.root)[0]).root;
    // Positive control: `x + 0` lives in one full expression, so the node
    // is island-admissible and the algebra rule rewrites it.
    var an = try analysisOf(&b);
    try testing.expect(try an.isSegSafe(body));
    // Move one operand into a fresh boundary: the node now spans two FEs,
    // so the ownership gate refuses island membership.
    const op0 = pr.operands(body)[0];
    pr.exprs.items[op0].full_expr = try pr.addFullExpr();
    try testing.expect(pr.node(op0).full_expr != pr.node(body).full_expr);
    var an2 = try analysisOf(&b);
    try testing.expect(!try an2.isSegSafe(body));
    // And the rule does not fire on the now-boundary-crossing subtree.
    _ = try hir_seg.optimize(b.arena.allocator(), b.built, .{ .graph = b.graph });
    try testing.expect(try funcHasNode(&b, "app.f", "add.i32"));
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

test "SEG: enabling the pass rewrites the AIR; both forms round-trip" {
    const src = try probe_corpus.read(testing.allocator, "probes/cases", "seg_off_by_default_air");
    defer testing.allocator.free(src);
    const off = try compileAir("app", src, false);
    defer testing.allocator.free(off);
    const on = try compileAir("app", src, true);
    defer testing.allocator.free(on);
    // `Options.seg` off (the library default) and on differ: `f`'s `x + 0`
    // is folded away only when the pass runs. Both programs are structurally
    // valid canonical AIR (the frontend validator runs inside compile); a
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

/// A compiled corpus program: the whole-pipeline load result (kept alive
/// for running) plus its canonical AIR text. The AIR is what makes the
/// four combinations comparable without recompiling: two combinations
/// whose AIR is byte-identical are the same program and cannot behave
/// differently, so only distinct AIRs are executed.
const Compiled = struct {
    l: support.Loaded,
    air: []u8,

    fn deinit(self: *Compiled) void {
        self.l.deinit();
        testing.allocator.free(self.air);
    }
};

/// Compile one corpus program through the whole pipeline under one
/// `--simplify` × `--seg` combination and print its canonical AIR.
fn compileProgram(text: []const u8, seg: bool, simplify: bool) !Compiled {
    var l = try support.loadOpts(text, false, seg, simplify);
    errdefer l.deinit();
    const program = l.compilation.program orelse return error.TestUnexpectedResult;
    return .{ .l = l, .air = try cfg.print(&program, testing.allocator) };
}

/// Run a compiled corpus program to completion, capturing output,
/// termination, and the panic / error detail. Does not fail the test on a
/// panic — the differential only requires the four combinations agree.
///
/// Each run uses its own arena: `VmHeap.deinit` frees only the
/// provenance registry, so Copy heap objects (strings, list cells) can
/// still be live when a run ends, and the leak checker is not part of
/// this semantic differential. The harness owns that arena and releases
/// it whole; it does not verify runtime leak-freedom.
fn runCompiled(c: *Compiled) !Term {
    var state = CaptureAdapter{};
    // The corpus imports std modules, so the root image alone cannot run:
    // build the whole-program artifact bundle and resolve `import`s through
    // its loader (the load-tests' pattern).
    var bundle_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer bundle_arena.deinit();
    var bundle = try artifact_bundle.ArtifactBundle.build(bundle_arena.allocator(), &(c.l.compilation.program orelse return error.TestUnexpectedResult));
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

/// The four `--simplify` × `--seg` combinations (hir.md §11): the M2b
/// consumers and SEG are independent passes, so every combination must
/// interpret a corpus program identically — output, termination, and
/// panic message (hir.md §10.3). Combination 0 is the all-off baseline
/// the other three are compared against.
const combos = [4]struct { seg: bool, simplify: bool }{
    .{ .seg = false, .simplify = false },
    .{ .seg = false, .simplify = true },
    .{ .seg = true, .simplify = false },
    .{ .seg = true, .simplify = true },
};

/// Parse a canonical AIR text with the standalone parser (air.md §13):
/// every combination's serialized form must round-trip, not just the
/// default one.
fn roundTripAir(air: []const u8, path: []const u8) !void {
    var p = cfg.Parser.init(testing.allocator);
    defer p.deinit();
    _ = p.parse(air) catch |err| {
        std.debug.print("SEG corpus: {s} canonical AIR does not round-trip ({s})\n", .{ path, @errorName(err) });
        return error.TestUnexpectedResult;
    };
}

/// Every `--simplify` × `--seg` combination must agree with the all-off
/// baseline verbatim — output, termination, and panic message (hir.md
/// §10.3) — and every combination's canonical AIR must round-trip
/// through the standalone parser. `expect_panic` pins the intended
/// termination so a coincidentally identical failure cannot pass as
/// coverage.
///
/// Combinations whose AIR equals the baseline's are not re-executed:
/// byte-identical AIR is the same program, so a second run could only
/// duplicate the baseline result. Only combinations that actually
/// rewrote something are run and compared. Returns a bitmask of the
/// differing combinations (`combos[1..]` order: bit 0 = simplify-only,
/// bit 1 = seg-only, bit 2 = both) so the caller can assert both passes
/// were exercised.
fn corpusDiff(dir: []const u8, spec: []const u8, expect_panic: bool) !usize {
    const path = try probe_corpus.path(testing.allocator, dir, spec);
    defer testing.allocator.free(path);
    const text = probe_corpus.read(testing.allocator, dir, spec) catch |err| {
        std.debug.print("SEG corpus: cannot read {s} ({s})\n", .{ path, @errorName(err) });
        return error.TestUnexpectedResult;
    };
    defer testing.allocator.free(text);
    // The differential must actually execute the program. A run error, or
    // the capture adapter's overflow sentinel, would make a matching
    // failure vacuous, so surface them.
    var base = try compileProgram(text, false, false);
    defer base.deinit();
    try roundTripAir(base.air, path);
    var baseline = try runCompiled(&base);
    defer baseline.deinit();
    const End = @TypeOf(baseline.end);
    const want: End = if (expect_panic) .panic else .normal;
    if (baseline.end == .failed) {
        std.debug.print("SEG corpus: {s} did not run (all off): {s} (output {d} bytes)\n", .{ path, baseline.detail, baseline.out.len });
        return error.TestUnexpectedResult;
    }
    if (baseline.end == .panic and std.mem.eql(u8, baseline.detail, "capture buffer overflow")) {
        std.debug.print("SEG corpus: {s} overflowed the capture buffer (all off)\n", .{path});
        return error.TestUnexpectedResult;
    }
    if (baseline.end != want) {
        std.debug.print("SEG corpus: {s} expected {s} termination, got (all off) {s} {s}\n", .{ path, @tagName(want), @tagName(baseline.end), baseline.detail });
        return error.TestUnexpectedResult;
    }
    var differed: usize = 0;
    for (combos[1..], 1..) |c, i| {
        var cc = try compileProgram(text, c.seg, c.simplify);
        defer cc.deinit();
        try roundTripAir(cc.air, path);
        if (std.mem.eql(u8, base.air, cc.air)) continue;
        differed |= @as(usize, 1) << @intCast(i - 1);
        var got = try runCompiled(&cc);
        defer got.deinit();
        const label = try std.fmt.allocPrint(testing.allocator, "simplify={} seg={}", .{ c.simplify, c.seg });
        defer testing.allocator.free(label);
        if (got.end == .failed) {
            std.debug.print("SEG corpus: {s} did not run ({s}): {s} (output {d} bytes)\n", .{ path, label, got.detail, got.out.len });
            return error.TestUnexpectedResult;
        }
        if (got.end == .panic and std.mem.eql(u8, got.detail, "capture buffer overflow")) {
            std.debug.print("SEG corpus: {s} overflowed the capture buffer ({s})\n", .{ path, label });
            return error.TestUnexpectedResult;
        }
        if (got.end != want) {
            std.debug.print("SEG corpus: {s} expected {s} termination, got {s} ({s}) {s}\n", .{ path, @tagName(want), label, @tagName(got.end), got.detail });
            return error.TestUnexpectedResult;
        }
        if (!Term.eql(baseline, got)) {
            std.debug.print("SEG corpus: {s} {s} interpretation differs from the all-off baseline\n", .{ path, label });
            return error.TestUnexpectedResult;
        }
    }
    return differed;
}

test "SEG corpus — examples/*.st compile+round-trip and every simplify×seg combination agrees" {
    var corpus = try probe_corpus.list(testing.allocator, "examples");
    defer corpus.deinit();
    for (corpus.names) |spec| {
        _ = try corpusDiff("examples", spec, false);
    }
}

test "SEG corpus — probes/*.st compile+round-trip and every simplify×seg combination agrees" {
    var corpus = try probe_corpus.list(testing.allocator, "probes");
    defer corpus.deinit();
    var differed: usize = 0;
    for (corpus.names) |spec| {
        differed |= try corpusDiff("probes", spec, probe_corpus.panics(spec));
    }
    // Non-vacuity: the probes carry the rewrite-triggering programs
    // (`consumers` / `cse` / `seg`, …), so each pass must have changed at
    // least one probe's AIR on its own and been run against the baseline.
    try testing.expect(differed & 0b01 != 0); // simplify alone rewrote something
    try testing.expect(differed & 0b10 != 0); // seg alone rewrote something
}

// ---------------------------------------------------------------------------
// Corpus budget: the recorded SEG compile-time / rounds / island baseline
// ---------------------------------------------------------------------------

// Drive SEG over the whole corpus (`probes/` + `examples/`), asserting
// the bounded-round contract holds for every program (`Stats.converged`)
// and aggregating the SEG compile time, rounds, and island coverage.
//
// This is the CI-safe half of the item-12 budget: a round-bound hit is
// exactly the regression the §8.2 contract makes observable, so the
// assertion is `converged`, never wall-clock (CI timing is not a stable
// oracle). The aggregate printed here — plus the measured figures
// recorded in hir.md §11 — is the baseline the default-on decision
// rests on.
//
// `slow` names the slowest corpus program (copied into a local buffer,
// since the corpus names are arena-freed per directory).
test "SEG budget — every corpus program converges inside the round bound" {
    var total_ns: u64 = 0;
    var total_iters: u64 = 0;
    var total_rewrites: u64 = 0;
    var total_islands: usize = 0;
    var total_nodes: usize = 0;
    var covered: usize = 0;
    var files: usize = 0;
    var slow_ns: u64 = 0;
    var slow_iters: u32 = 0;
    var slow_islands: usize = 0;
    var slow_buf: [96]u8 = undefined;
    var slow: []const u8 = "";

    for ([_][]const u8{ "probes", "examples" }) |dir| {
        var corpus = try probe_corpus.list(testing.allocator, dir);
        defer corpus.deinit();
        for (corpus.names) |spec| {
            const text = try probe_corpus.read(testing.allocator, dir, spec);
            defer testing.allocator.free(text);
            var b = buildText("app", &.{.{ "app", text }}) catch |err| {
                std.debug.print("SEG budget: {s}/{s} HIR build failed ({s})\n", .{ dir, spec, @errorName(err) });
                return error.TestUnexpectedResult;
            };
            defer b.deinit();
            const nodes = b.built.program.exprs.items.len;
            const t0 = std.Io.Clock.awake.now(testing.io);
            const stats = hir_seg.optimize(b.arena.allocator(), b.built, .{ .graph = b.graph }) catch |err| {
                std.debug.print("SEG budget: {s}/{s} SEG failed ({s})\n", .{ dir, spec, @errorName(err) });
                return error.TestUnexpectedResult;
            };
            const ns: u64 = @intCast(t0.durationTo(std.Io.Clock.awake.now(testing.io)).nanoseconds);
            if (!stats.converged) {
                std.debug.print("SEG budget: {s}/{s} hit the round bound without converging ({d} rounds)\n", .{ dir, spec, stats.iterations });
                return error.TestUnexpectedResult;
            }
            files += 1;
            total_ns += ns;
            total_iters += stats.iterations;
            total_rewrites += stats.beta + stats.etas + stats.folds + stats.algebra + stats.lets + stats.conds + stats.matches + stats.projects + stats.shares;
            total_islands += stats.islands;
            total_nodes += nodes;
            if (stats.islands > 0) covered += 1;
            if (ns > slow_ns) {
                slow_ns = ns;
                slow_iters = stats.iterations;
                slow_islands = stats.islands;
                slow = std.fmt.bufPrint(&slow_buf, "{s}/{s}", .{ dir, spec }) catch unreachable;
            }
        }
    }
    std.debug.print(
        "SEG budget baseline: {d} files, {d} islands / {d} reachable nodes ({d} files with islands), {d} rounds, {d} rewrites, {d} ms total; slowest {s} {d} ms ({d} rounds, {d} islands)\n",
        .{ files, total_islands, total_nodes, covered, total_iters, total_rewrites, total_ns / std.time.ns_per_ms, slow, slow_ns / std.time.ns_per_ms, slow_iters, slow_islands },
    );
    try testing.expect(files > 0);
    try testing.expect(covered > 0);
}
