//! HIR black-box suite — cross-module tests of the AST→HIR builder and
//! the built-program container (hir.md §11).
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
const hir_effects = @import("passes/hir_effects.zig");
const probe_corpus = @import("probe_corpus.zig");
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

/// Validate every function root of the built program (acceptance:
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

/// Black-box acceptance (hir.md §11, effects.md §14): run the effect
/// analysis over a built program and validate the annotations. This is
/// the seam the frontend runs between HIR build and HIR→CFG lowering.
fn expectEffectsAll(built: *hir.BuiltProgram, graph: *moduleinfo.ModuleGraph) !void {
    var an = try hir_effects.Analysis.init(built.arena, built, .{ .graph = graph });
    try an.analyze();
    if (try an.validate(built.arena)) |m| {
        std.debug.print("EFFECT VALIDATE FAIL: {s}\n", .{m});
        return error.TestUnexpectedResult;
    }
    // Every function root and constant initializer must be annotated.
    for (built.funcs.items) |f| {
        if (built.program.effectOf(f.root).readyId() == null) {
            std.debug.print("EFFECT ANNOTATION MISSING on '{s}'\n", .{f.name});
            return error.TestUnexpectedResult;
        }
    }
    for (built.consts.items) |c| {
        const root = c.init orelse continue;
        if (built.program.effectOf(root).readyId() == null) {
            std.debug.print("EFFECT ANNOTATION MISSING on const '{s}'\n", .{c.key});
            return error.TestUnexpectedResult;
        }
    }
}

test "build: build fib-class module and validate every function root" {
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
    try expectEffectsAll(b.built, b.graph);
}

// ---------------------------------------------------------------------------
// Source spans (hir.md §3.2): the builder records every source-built
// node's AST span in the interned `origins` side table; synthetic nodes
// (module-init λ, canonical-text rebuilds) keep none.
// ---------------------------------------------------------------------------

/// Every node reachable from `root` (operands, then region roots).
fn reachableNodes(alloc: std.mem.Allocator, pr: *const hir.Program, root: hir.ExprId) !std.ArrayList(hir.ExprId) {
    var out = std.ArrayList(hir.ExprId).empty;
    errdefer out.deinit(alloc);
    var work = std.ArrayList(hir.ExprId).empty;
    defer work.deinit(alloc);
    try work.append(alloc, root);
    while (work.pop()) |id| {
        try out.append(alloc, id);
        for (pr.operands(id)) |op| try work.append(alloc, op);
        for (pr.regionsOf(id)) |rid| try work.append(alloc, pr.region(rid).root);
    }
    return out;
}

test "build: source spans — built nodes carry their AST span, synthetics none" {
    var b = try buildText("app", &.{
        .{ "lib", "fn twice(n: int32) -> int32 { n + n }" },
        .{
            "app",
            \\const builtin = import("builtin");
            \\const lib = import("lib");
            \\fn fib(n: int32) -> int32 {
            \\    if (n < 2) { n } else { fib(n - 1) + fib(n - 2) }
            \\}
            \\fn main() -> void {
            \\    builtin.print(builtin.str(lib.twice(fib(5))));
            \\}
        },
    });
    defer b.deinit();
    const pr = &b.built.program;
    const app_src = b.graph.module("app").?.source.?;
    const lib_src = b.graph.module("lib").?.source.?;

    var fib_root: ?hir.ExprId = null;
    var main_root: ?hir.ExprId = null;
    for (b.built.funcs.items) |f| {
        if (std.mem.eql(u8, f.name, "app.fib")) fib_root = f.root;
        if (std.mem.eql(u8, f.name, "app.main")) main_root = f.root;
        if (std.mem.eql(u8, f.name, "lib.twice")) {
            const sp = pr.originOf(f.root) orelse return error.TestUnexpectedResult;
            try testing.expectEqual(lib_src.id, sp.source);
            try testing.expectEqualStrings("twice", lib_src.text[sp.start..sp.end]);
        }
    }
    const fib = fib_root orelse return error.TestUnexpectedResult;
    const main = main_root orelse return error.TestUnexpectedResult;

    // Member-function λ roots carry the declaration's name span...
    const fib_decl = pr.originOf(fib) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(app_src.id, fib_decl.source);
    try testing.expectEqualStrings("fib", app_src.text[fib_decl.start..fib_decl.end]);

    // ...and every node in a source-built body resolves to a span inside
    // its own module's source (multi-module: fib/twice origins never
    // cross). The one legitimate exception is the synthesized void tail
    // of a discarded-void statement (`seq(call, void)`), which is built
    // without a source position.
    for ([_]hir.ExprId{ fib, main }) |root| {
        var nodes = try reachableNodes(testing.allocator, pr, root);
        defer nodes.deinit(testing.allocator);
        try testing.expect(nodes.items.len > 1);
        var synthetic_voids: usize = 0;
        for (nodes.items) |id| {
            const n = pr.node(id);
            const is_void_const = n.payload == .const_value and n.payload.const_value == .void;
            if (pr.originOf(id)) |sp| {
                try testing.expectEqual(app_src.id, sp.source);
                try testing.expect(sp.end <= app_src.text.len and sp.start < sp.end);
            } else {
                try testing.expect(is_void_const);
                synthetic_voids += 1;
            }
        }
        // fib has none; main has exactly the discarded print's tail.
        const want: usize = if (root == main) 1 else 0;
        try testing.expectEqual(want, synthetic_voids);
    }

    // Exact-span spot checks in main: the literal, and the inner call.
    var nodes = try reachableNodes(testing.allocator, pr, main);
    defer nodes.deinit(testing.allocator);
    var saw_five = false;
    var saw_inner_call = false;
    for (nodes.items) |id| {
        const n = pr.node(id);
        const sp = pr.originOf(id) orelse continue; // synthetic void tail
        const text = app_src.text[sp.start..sp.end];
        if (n.payload == .const_value and n.payload.const_value == .int and n.payload.const_value.int == 5) {
            try testing.expectEqualStrings("5", text);
            saw_five = true;
        }
        if (hir.registry.get(n.op).name.len == 4 and std.mem.eql(u8, hir.registry.get(n.op).name, "call") and std.mem.eql(u8, text, "fib(5)")) {
            saw_inner_call = true;
        }
    }
    try testing.expect(saw_five and saw_inner_call);

    // Synthetics: the module-init λ records are predeclared spanless.
    for (b.built.funcs.items) |f| {
        if (f.kind == .init) try testing.expect(pr.originOf(f.root) == null);
    }
    try expectValidAll(b.built);
}

/// The corpus harness: compile every `dir/*.st` module as its own entry
/// (each file read from disk at the repo root — `zig build test` runs
/// there, like `zig build examples`), build the HIR, and validate every
/// function root. The directory is enumerated at test time, so a new
/// probe joins automatically; a module that fails to build or validate
/// is a loud failure (no silent skips).
fn corpusList(dir: []const u8) !void {
    var failures = std.ArrayList([]const u8).empty;
    defer failures.deinit(testing.allocator);
    var corpus = try probe_corpus.list(testing.allocator, dir);
    defer corpus.deinit();
    for (corpus.names) |spec| {
        const path = try probe_corpus.path(testing.allocator, dir, spec);
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
        expectEffectsAll(b.built, b.graph) catch {
            std.debug.print("HIR corpus: {s} failed effect validation\n", .{path});
            testing.allocator.free(text);
            return error.TestUnexpectedResult;
        };
        testing.allocator.free(text);
    }
    _ = &failures;
}

// ---------------------------------------------------------------------------
// Module-constant init/teardown dependency check (docs/effects.md §7).
// The check moved out of the checker's AST-level `InitOrder` walk and is now
// driven by the function summaries + whole-chain `drop_effect`; these cases
// are the AST-walk suite relocated to the phase-3 seam that owns the rule.
// ---------------------------------------------------------------------------

/// Compile one module through the full frontend. Returns a diagnostic
/// message (copied into `allocator`) or null on success.
fn compileDiag(text: []const u8, allocator: std.mem.Allocator) !?[]const u8 {
    var source_map = std.StringHashMapUnmanaged([]const u8).empty;
    defer source_map.deinit(allocator);
    try source_map.put(allocator, "test", text);
    var comp = frontend.compile(allocator, .{
        .entry = "test",
        .sources = .{ .source = source_map },
    }) catch |err| switch (err) {
        error.Diagnostic => return null,
        else => return err,
    };
    defer comp.deinit();
    if (comp.diag) |d| return try allocator.dupe(u8, d.message);
    return null;
}

fn expectModuleDiag(text: []const u8, want: []const u8) !void {
    const msg = (try compileDiag(text, testing.allocator)) orelse {
        std.debug.print("expected a diagnostic containing '{s}', got none\n", .{want});
        return error.TestUnexpectedResult;
    };
    defer testing.allocator.free(msg);
    if (std.mem.indexOf(u8, msg, want) == null) {
        std.debug.print("expected '{s}' in '{s}'\n", .{ want, msg });
        return error.TestUnexpectedResult;
    }
}

fn expectModuleOk(text: []const u8) !void {
    if (try compileDiag(text, testing.allocator)) |msg| {
        defer testing.allocator.free(msg);
        std.debug.print("unexpected diagnostic: {s}\n", .{msg});
        return error.TestUnexpectedResult;
    }
}

test "consumers: rejects reading a later module constant (summary-driven)" {
    try expectModuleDiag(
        \\const a: int32 = b;
        \\const b: int32 = 1;
    , "module constant initializer reads 'b' declared later");
}

test "consumers: rejects transitively reading a later module constant" {
    try expectModuleDiag(
        \\const a: int32 = f();
        \\fn f() -> int32 { b }
        \\const b: int32 = 1;
    , "which reads module constant 'b' declared later");
}

test "consumers: accepts reading an earlier module constant" {
    try expectModuleOk(
        \\const a = 1;
        \\const b = a;
    );
}

test "consumers: accepts an indirect call reading an earlier module constant" {
    // The callable is a `let`-bound local, so the §9.2 target narrowing
    // resolves it to `pick` and the initializer's read set is `Read(a)` —
    // not the unknown read set an unresolved indirect call would carry
    // (which §7.1/§9.4 reject). Without the narrowing this program is
    // refused with "reads 'a' before it is initialized".
    try expectModuleOk(
        \\const a: int32 = 1;
        \\fn pick() -> int32 { a }
        \\const b: int32 = { let f = pick; f() };
    );
}

test "consumers: a function reading a later constant is fine when nothing calls it" {
    try expectModuleOk(
        \\const a = 1;
        \\fn f() -> int32 { b }
        \\const b: int32 = 2;
    );
}

test "consumers: rejects a drop hook reading a later module constant" {
    try expectModuleDiag(
        \\struct File { fd: int32; drop(f) { let _ = later_msg; } }
        \\const log: File = File{ fd: 1 };
        \\const later_msg: str = "bye";
    , "drop hook of module constant 'log' reads 'later_msg' declared later");
}

test "consumers: rejects a drop hook transitively reading a later module constant" {
    try expectModuleDiag(
        \\fn tell() -> str { later_msg }
        \\struct File { fd: int32; drop(f) { let _ = tell(); } }
        \\const log: File = File{ fd: 1 };
        \\const later_msg: str = "bye";
    , "which reads module constant 'later_msg' declared later");
}

test "consumers: accepts a drop hook reading an earlier module constant" {
    try expectModuleOk(
        \\const earlier: str = "hi";
        \\struct File { fd: int32; drop(f) { let _ = earlier; } }
        \\const log: File = File{ fd: 1 };
    );
}

test "consumers: a mutual call cycle reading no constants is fine" {
    try expectModuleOk(
        \\const a: int32 = f();
        \\fn f() -> int32 { g() }
        \\fn g() -> int32 { f() }
    );
}

test "consumers: a recursive SCC's transitive read is caught (fixpoint drives the check)" {
    // docs/effects.md §7.1/§8.2: the read is only in `g`, reachable from
    // the initializer through a recursive SCC — the fixed-point summary of
    // `f` must still carry it.
    try expectModuleDiag(
        \\const a: int32 = f();
        \\fn f() -> int32 { g() }
        \\fn g() -> int32 { f() + b }
        \\const b: int32 = 1;
    , "which reads module constant 'b' declared later");
}

test "consumers: rejects a module constant reading itself" {
    try expectModuleDiag(
        \\const a: int32 = a;
    , "reads 'a' before it is initialized");
}

test "consumers: rejects a module constant reading itself through a call" {
    try expectModuleDiag(
        \\const a: int32 = f();
        \\fn f() -> int32 { a }
    , "which reads module constant 'a' declared later");
}

fn validateAllMsg(built: *const hir.BuiltProgram) ?[]const u8 {
    for (built.funcs.items) |f| {
        const msg = hir.validate(&built.program, f.root, testing.allocator) catch return "validate oom";
        if (msg) |m| return m;
    }
    return null;
}

fn findFunc(built: *const hir.BuiltProgram, name: []const u8) !hir.FuncRecord {
    for (built.funcs.items) |f| {
        if (std.mem.eql(u8, f.name, name)) return f;
    }
    return error.TestUnexpectedResult;
}

/// Assert every node of `root`'s subtree belongs to full expression `fe`.
fn expectSubtreeFe(pr: *const hir.Program, root: hir.ExprId, fe: hir.FullExprId) !void {
    var work = std.ArrayList(hir.ExprId).empty;
    defer work.deinit(testing.allocator);
    try work.append(testing.allocator, root);
    while (work.pop()) |id| {
        try testing.expectEqual(fe, pr.node(id).full_expr);
        for (pr.operands(id)) |op| try work.append(testing.allocator, op);
        for (pr.regionsOf(id)) |r| try work.append(testing.allocator, pr.region(r).root);
    }
}

test "build: node-level full expressions split on let initializers (hir.md §5.6)" {
    var b = try buildText("app", &.{.{
        "app",
        \\fn same(x: int32) -> int32 { (x + 1) + (x + 2) }
        \\fn split(x: int32) -> int32 { let y = x + 1; y + 2 }
        \\fn main() -> void { }
    }});
    defer b.deinit();
    const pr = &b.built.program;

    // One expression, one full expression: every node shares the body's
    // boundary, and the `lambda` root carries its body's FE too.
    const same = try findFunc(b.built, "app.same");
    const same_body = pr.region(pr.regionsOf(same.root)[0]).root;
    const same_fe = pr.node(same_body).full_expr;
    try testing.expect(same_fe != 0);
    try testing.expectEqual(same_fe, pr.node(same.root).full_expr);
    try expectSubtreeFe(pr, same_body, same_fe);

    // A `let` initializer opens a nested boundary: the init subtree is a
    // full expression of its own, disjoint from the `let` + body FE.
    const split = try findFunc(b.built, "app.split");
    const let_node = pr.region(pr.regionsOf(split.root)[0]).root;
    try testing.expect(std.mem.eql(u8, hir.registry.get(pr.node(let_node).op).name, "let"));
    const let_fe = pr.node(let_node).full_expr;
    const init = pr.operands(let_node)[0];
    const init_fe = pr.node(init).full_expr;
    try testing.expect(init_fe != let_fe);
    try expectSubtreeFe(pr, init, init_fe);
    // The region body forwards its value and stays in the enclosing FE.
    try expectSubtreeFe(pr, pr.region(pr.regionsOf(let_node)[0]).root, let_fe);
    // A second statement would open its own FE; this body has none (the
    // `let` is the whole result expression).
    try testing.expectEqual(let_fe, pr.node(split.root).full_expr);
}

test "build: a cleanup token whose origin node left its full expression is rejected" {
    var b = try buildText("app", &.{.{
        "app",
        \\struct Token { id: int32; drop(t) { let x = t.id; } }
        \\fn make(id: int32) -> Token { Token { id: id } }
        \\fn f(id: int32) -> int32 { let _ = make(id); 7 }
    }});
    defer b.deinit();
    const pr = &b.built.program;
    try testing.expect(pr.cleanup_modeled);
    try testing.expect(pr.cleanup_tokens.items.len > 0);
    const tk = pr.cleanup_tokens.items[0];
    // Consistent by construction (the validator's new FE invariant).
    const msg = try hir.validate(pr, b.built.funcs.items[b.built.funcs.items.len - 1].root, testing.allocator);
    if (msg) |m| {
        defer testing.allocator.free(m);
        std.debug.print("FE invariant should hold: {s}\n", .{m});
        return error.TestUnexpectedResult;
    }
    // Move the origin node into a fresh boundary: the token now points at
    // a value whose boundary differs from the one it is registered on.
    pr.exprs.items[tk.origin_expr].full_expr = try pr.addFullExpr();
    const bad = try hir.validate(pr, b.built.funcs.items[b.built.funcs.items.len - 1].root, testing.allocator);
    if (bad) |m| {
        testing.allocator.free(m);
    } else {
        return error.TestUnexpectedResult;
    }
}

test "build: HIR corpus — examples/*.st build and validate" {
    try corpusList("examples");
}

test "build: HIR corpus — probes/*.st build and validate" {
    try corpusList("probes");
}

// ---------------------------------------------------------------------------
// Canonical-text round-trip (hir.md §4.9): every built function root of
// the corpus prints to canonical text that re-parses to an α-equivalent
// program that passes the structural validator. Covers box types,
// aggregate member identity, and destructuring lets.
// ---------------------------------------------------------------------------

fn corpusRoundTrip(dir: []const u8) !void {
    var corpus = try probe_corpus.list(testing.allocator, dir);
    defer corpus.deinit();
    for (corpus.names) |spec| {
        const text = try probe_corpus.read(testing.allocator, dir, spec);
        defer testing.allocator.free(text);
        var b = buildText(spec, &.{.{ spec, text }}) catch |err| {
            std.debug.print("HIR round-trip: {s}/{s} failed to build: {s}\n", .{ dir, spec, @errorName(err) });
            return error.TestUnexpectedResult;
        };
        defer b.deinit();
        const ctx = try b.built.serCtx();
        for (b.built.funcs.items) |f| {
            // `hir.print` allocates its ref/binder tables from the passed
            // allocator and expects an arena owner (see `print`); use one
            // per function so the test allocator sees no leaks.
            var pr_arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer pr_arena.deinit();
            const printed = hir.print(&b.built.program, f.root, pr_arena.allocator(), ctx) catch |err| {
                std.debug.print("HIR round-trip: {s}/{s} @{s} print failed: {s}\n", .{ dir, spec, f.name, @errorName(err) });
                return error.TestUnexpectedResult;
            };
            var parsed = hir.parseText(printed, ctx) catch |err| {
                std.debug.print("HIR round-trip: {s}/{s} @{s} parse failed: {s}\n", .{ dir, spec, f.name, @errorName(err) });
                return error.TestUnexpectedResult;
            };
            defer parsed.arena.deinit();
            if (try hir.validate(&parsed.program, parsed.root, testing.allocator)) |m| {
                defer testing.allocator.free(m);
                std.debug.print("HIR round-trip: {s}/{s} @{s} validate failed: {s}\n", .{ dir, spec, f.name, m });
                return error.TestUnexpectedResult;
            }
            if (!hir.alphaEq(testing.allocator, &b.built.program, f.root, &parsed.program, parsed.root)) {
                const reprint = hir.print(&parsed.program, parsed.root, pr_arena.allocator(), ctx) catch "(reprint failed)";
                std.debug.print("HIR round-trip: {s}/{s} @{s} is not alpha-equivalent\n  printed: {s}\n  reparsed: {s}\n", .{ dir, spec, f.name, printed, reprint });
                return error.TestUnexpectedResult;
            }
        }
    }
}

test "text: HIR canonical text round-trips over examples/*.st" {
    try corpusRoundTrip("examples");
}

test "text: HIR canonical text round-trips over probes/*.st" {
    try corpusRoundTrip("probes");
}
// ---------------------------------------------------------------------------
// Canonical-AIR seam checks (hir.md §10.3/§11). The corpus gate checks what
// remains verifiable without an oracle: every corpus file compiles through
// the HIR seam into canonical AIR that CFG-validates (inside
// `frontend.compile`) and round-trips the standalone cfg parser.
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
        std.debug.print("canonical-AIR corpus compile failed: {s}\n", .{d.message});
    } else {
        std.debug.print("canonical-AIR corpus compile failed (no diagnostic)\n", .{});
    }
    return error.TestUnexpectedResult;
}

/// One corpus file: compile → canonical AIR → standalone cfg-parse
/// round-trip (parse-back must succeed; the frontend already ran the
/// CFG validator inside compile).
fn airRoundTrip(dir: []const u8, spec: []const u8) !void {
    const path = try probe_corpus.path(testing.allocator, dir, spec);
    defer testing.allocator.free(path);
    const text = probe_corpus.read(testing.allocator, dir, spec) catch |err| {
        std.debug.print("canonical-AIR corpus: cannot read {s} ({s})\n", .{ path, @errorName(err) });
        return error.TestUnexpectedResult;
    };
    defer testing.allocator.free(text);

    const air = try compileText(spec, text);
    defer testing.allocator.free(air);
    var p = cfg.Parser.init(testing.allocator);
    defer p.deinit();
    const prog = p.parse(air) catch |err| {
        std.debug.print("canonical-AIR corpus: {s} canonical AIR does not round-trip ({s})\n", .{ path, @errorName(err) });
        return error.TestUnexpectedResult;
    };
    if (prog.funcs.len == 0) {
        std.debug.print("canonical-AIR corpus: {s} canonical AIR has no functions\n", .{path});
        return error.TestUnexpectedResult;
    }
}

fn airRoundTripAll(dir: []const u8) !void {
    var corpus = try probe_corpus.list(testing.allocator, dir);
    defer corpus.deinit();
    for (corpus.names) |spec| try airRoundTrip(dir, spec);
}

test "seam: canonical-AIR seam — examples/*.st compile and round-trip" {
    try airRoundTripAll("examples");
}

test "seam: canonical-AIR seam — probes/*.st compile and round-trip" {
    try airRoundTripAll("probes");
}

// ---------------------------------------------------------------------------
// The only place module-value chains are textually checked:
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
        std.debug.print("canonical-AIR markers: compile failed: {s}\n", .{if (hc.diag) |d| d.message else "(no diagnostic)"});
        return error.TestUnexpectedResult;
    }
    const hir_text = try cfg.print(&hc.program.?, testing.allocator);
    defer testing.allocator.free(hir_text);
    for (needles) |n| {
        if (std.mem.indexOf(u8, hir_text, n) == null) {
            std.debug.print("canonical-AIR markers: missing '{s}' in canonical AIR\n", .{n});
            return error.TestUnexpectedResult;
        }
    }
    for (absent) |n| {
        if (std.mem.indexOf(u8, hir_text, n) != null) {
            std.debug.print("canonical-AIR markers: unexpected '{s}' in canonical AIR\n", .{n});
            return error.TestUnexpectedResult;
        }
    }
}

test "seam: module-value chains replay in canonical AIR" {
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
