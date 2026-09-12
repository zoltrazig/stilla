//! Pass: SEG v1 — the Slotted E-Graph consumer for the M2a rule subset
//! (docs/hir.md §8, §11 M2a; docs/effects.md §12.3). In: a built HIR
//! program whose every reachable node carries a *validated* `ready`
//! effect summary (`hir_effects.Analysis`). Out: the same program with
//! its admissible pure-Copy islands rewritten by the v1 rules, iterated
//! to a bounded fixpoint, with every root still structurally valid and
//! its annotations re-derivable.
//!
//! Scope (hir.md §11 M2a):
//!
//! - **Island set** — `const / local / let / lambda / call / if / match /
//!   struct_make / variant_make / field_get` plus every typed (numeric) opcode,
//!   exactly the registry rows carrying `OpDescriptor.seg` (hir.md §3.5). The
//!   real boundary is the *recursive* encodability predicate: a node is
//!   an island member only if its own encoding is registered, it is
//!   semantically `isSegSafe`, and every operand subtree / region body is
//!   itself an island member (hir.md §8.1–§8.2). Anything else keeps its
//!   original shape.
//! - **Rules** — β-reduction (→ let, the v1 boundary rewrite with the
//!   §8.4 contract), let simplification (dead let, used-once forwarding,
//!   trivial-atom forwarding), constant folding over the typed reps,
//!   integer algebra identities, and the known-variant `match` reduction
//!   to `let` (§8.6). Not in scope: associativity / commutativity search,
//!   CSE, η-reduction, `move` / `drop` / borrow, host calls (§8.3).
//! - **Extraction cost** — v1 uses minimal node count plus a
//!   deterministic rule order as the tie-break (hir.md §8.2). The let /
//!   folding / algebra rules strictly reduce `costOf`; β (a boundary
//!   rewrite, not an e-class extraction) is admitted by its contract and
//!   the known-variant `match` reduction by its coverage / arity proof.
//!   The `match` rule splices one `let` per bound payload, so a wide
//!   constructor can add nodes: termination comes from the bounded
//!   `max_iterations` rounds (each `match` node is consumed once), not
//!   from a globally decreasing cost.
//! - **Re-verification** — each iteration re-derives the effect analysis
//!   from scratch before rewriting; the caller re-validates structurally
//!   and by effects after the pass. No transform is allowed to rely on
//!   the pre-rewrite static conclusions (hir.md §2.4).
//! - **Off by default** — enabled by `frontend.Options.seg` / `--seg`.
//!
//! The rewriter is deliberately in-place: HIR is an append-only arena and
//! every node has exactly one parent (§3.7), so mutating a node's fields
//! (or copying a rewritten child's fields into it) is a local, tree-legal
//! rewrite. A rule never *moves* a node it will keep referencing; β and
//! let-forwarding copy the surviving operand's fields into the node being
//! rewritten and leave the donor node unreachable.

const std = @import("std");
const meta = @import("stilla").meta;
const hir = @import("stilla").hir;
const moduleinfo = @import("stilla").moduleinfo;
const effects = @import("stilla").effects;
const hir_effects = @import("hir_effects.zig");

pub const Error = std.mem.Allocator.Error;

/// What one `optimize` call did — for tests and the compile-time budget.
pub const Stats = struct {
    iterations: u32 = 0,
    /// Reachable nodes that passed recursive island admission.
    islands: usize = 0,
    beta: usize = 0,
    folds: usize = 0,
    algebra: usize = 0,
    lets: usize = 0,
    conds: usize = 0,
    matches: usize = 0,
};

pub const Config = struct {
    /// The module graph, for the ownership class of generic named types
    /// (same role as in `hir_effects.Config`).
    graph: ?*moduleinfo.ModuleGraph = null,
    /// Embedding host declarations (docs/effects.md §13), passed through
    /// to every internal `hir_effects.Analysis` so the rewrite rounds and
    /// the caller's final re-validation use one effect environment.
    host_decls: []const effects.HostDecl = &.{},
    /// Effect-domain registry (docs/effects.md §5.5–§5.6), passed through
    /// with `host_decls` so the rounds and the re-validation share one
    /// environment.
    resources: effects.ResourceRegistry = .{},
    /// Bound on analysis→rewrite rounds (each round re-derives effects).
    max_iterations: u32 = 8,
};

/// Rewrite every function body and constant initializer in place to the
/// SEG v1 normal form, iterating analysis/rewrite to a bounded fixpoint.
/// The caller owns `built` and the arena; on return every root is
/// rewritten but not yet re-validated (the caller runs
/// `hir.validate` + a fresh `Analysis.analyze`/`.validate`).
pub fn optimize(arena: std.mem.Allocator, built: *hir.BuiltProgram, config: Config) Error!Stats {
    var stats = Stats{};
    // A λ record is inlined at most once per compile: this bounds β
    // against recursive / mutually-recursive λ values (hir.md §8.4 does
    // not promise multi-site inlining) and keeps the fixpoint finite.
    var beta_done = std.AutoHashMapUnmanaged(hir.FuncId, void).empty;
    var iter: u32 = 0;
    while (iter < config.max_iterations) : (iter += 1) {
        var analysis = try hir_effects.Analysis.init(arena, built, .{ .graph = config.graph, .host_decls = config.host_decls, .resources = config.resources });
        try analysis.analyze();
        var rw = Rewriter{
            .arena = arena,
            .built = built,
            .analysis = &analysis,
            .beta_done = &beta_done,
        };
        const changed = try rw.run();
        stats.iterations += 1;
        stats.islands = @max(stats.islands, rw.island_count);
        stats.beta += rw.beta;
        stats.folds += rw.folds;
        stats.algebra += rw.algebra;
        stats.lets += rw.lets;
        stats.conds += rw.conds;
        stats.matches += rw.matches;
        if (!changed) break;
    }
    return stats;
}

// ---------------------------------------------------------------------------
// The rewriter
// ---------------------------------------------------------------------------

const Rewriter = struct {
    arena: std.mem.Allocator,
    built: *hir.BuiltProgram,
    analysis: *hir_effects.Analysis,
    beta_done: *std.AutoHashMapUnmanaged(hir.FuncId, void),

    /// Per-node island membership for the nodes present when the pass
    /// started. Nodes created by this pass (β clones) are admissible by
    /// construction and are not in this slice — `encOf` answers `true`
    /// for them.
    enc: []bool = &.{},
    island_count: usize = 0,

    changed: bool = false,
    beta: usize = 0,
    folds: usize = 0,
    algebra: usize = 0,
    lets: usize = 0,
    conds: usize = 0,
    matches: usize = 0,

    /// The full-expression id β maps every cloned λ-body node onto
    /// (hir.md §8.4 `maps_full_expr`): the call site's FE. The M1a
    /// builder keeps FE 0 everywhere, so this is the identity today; the
    /// explicit mapping keeps β correct once real FE boundaries land.
    clone_fe: hir.FullExprId = 0,

    fn p(self: *Rewriter) *hir.Program {
        return &self.built.program;
    }

    fn run(self: *Rewriter) Error!bool {
        self.enc = try self.arena.alloc(bool, self.p().exprs.items.len);
        @memset(self.enc, false);
        try self.computeIslands();
        for (self.built.funcs.items) |rec| try self.rewrite(rec.root);
        for (self.built.consts.items) |c| {
            if (c.init) |root| try self.rewrite(root);
        }
        return self.changed;
    }

    /// `true` when `id` is inside an island. For nodes appended by this
    /// pass (the cloned body and the `let` chain β splices) that is a
    /// structural given, not a claim about stale annotations.
    fn encOf(self: *Rewriter, id: hir.ExprId) bool {
        if (id < self.enc.len) return self.enc[id];
        return true;
    }

    /// A node's analysis annotation is only meaningful while the pass has
    /// not rewritten its *content*; β is the only rule that consults the
    /// analysis (via `tryBeta`) and it runs before any rewrite at that id.
    fn analysisValid(self: *Rewriter, id: hir.ExprId) bool {
        return id < self.enc.len;
    }

    /// Recursive island admission (hir.md §8.1): encoding registered,
    /// semantically seg-safe, and every operand / region body an island
    /// member. Computed once per pass over the pre-rewrite tree;
    /// bottom-up so each node's children are already classified.
    fn computeIslands(self: *Rewriter) Error!void {
        const pr = self.p();
        var order = std.ArrayListUnmanaged(hir.ExprId).empty;
        defer order.deinit(self.arena);
        var stack = std.ArrayListUnmanaged(hir.ExprId).empty;
        defer stack.deinit(self.arena);
        for (self.built.funcs.items) |rec| try stack.append(self.arena, rec.root);
        for (self.built.consts.items) |c| {
            if (c.init) |root| try stack.append(self.arena, root);
        }
        while (stack.pop()) |id| {
            try order.append(self.arena, id);
            for (pr.operands(id)) |op| try stack.append(self.arena, op);
            for (pr.regionsOf(id)) |r| try stack.append(self.arena, pr.region(r).root);
        }
        var i = order.items.len;
        while (i > 0) {
            i -= 1;
            const id = order.items[i];
            const d = hir.registry.get(pr.node(id).op);
            var ok = d.seg != null and (try self.analysis.isSegSafe(id));
            if (ok) {
                for (pr.operands(id)) |op| {
                    if (!self.enc[op]) {
                        ok = false;
                        break;
                    }
                }
            }
            if (ok) {
                for (pr.regionsOf(id)) |r| {
                    if (!self.enc[pr.region(r).root]) {
                        ok = false;
                        break;
                    }
                }
            }
            self.enc[id] = ok;
            if (ok) self.island_count += 1;
        }
    }

    // -----------------------------------------------------------------
    // Driver
    // -----------------------------------------------------------------

    fn rewrite(self: *Rewriter, id: hir.ExprId) Error!void {
        // β is a boundary rewrite (hir.md §8.4), not an island rewrite:
        // its callee is a `fn_ref`, which has no SEG encoding, so the
        // call is never an island member. It is admitted by its contract
        // inside `tryBeta` instead of by the island predicate.
        if (self.analysisValid(id)) {
            if (try self.tryBeta(id)) {
                self.changed = true;
                self.beta += 1;
                // The call node now holds a let chain; simplify it (and
                // recurse into the freshly cloned body). The result is
                // island-internal by construction, so rules are allowed
                // even though the original call id was not an island.
                try self.rewriteChildren(id);
                _ = try self.applyRules(id, true);
                return;
            }
        }
        try self.rewriteChildren(id);
        if (try self.applyRules(id, self.encOf(id))) self.changed = true;
    }

    /// Copy the operand/region/param id lists into arena-owned slices
    /// before any work that may append to the program's flat buffers.
    /// `Program.operands`/`regionsOf`/`params` return slices into
    /// `expr_buffer`/`region_buffer`/`binder_buffer`; an append (a rule
    /// materializing a new node, a β clone) can reallocate those buffers
    /// and move the memory out from under such a slice.
    fn dupOperands(self: *Rewriter, id: hir.ExprId) Error![]hir.ExprId {
        const src = self.p().operands(id);
        const out = try self.arena.alloc(hir.ExprId, src.len);
        @memcpy(out, src);
        return out;
    }

    fn dupRegions(self: *Rewriter, id: hir.ExprId) Error![]hir.RegionId {
        const src = self.p().regionsOf(id);
        const out = try self.arena.alloc(hir.RegionId, src.len);
        @memcpy(out, src);
        return out;
    }

    fn dupParams(self: *Rewriter, rid: hir.RegionId) Error![]hir.BinderId {
        const src = self.p().params(rid);
        const out = try self.arena.alloc(hir.BinderId, src.len);
        @memcpy(out, src);
        return out;
    }

    /// Recurse into the operands and region roots. Ids are stable across
    /// rewriting (rules mutate a node's fields, never its position), so
    /// no parent slot has to be updated.
    fn rewriteChildren(self: *Rewriter, id: hir.ExprId) Error!void {
        const pr = self.p();
        const ops = try self.dupOperands(id);
        for (ops) |op| try self.rewrite(op);
        const regs = try self.dupRegions(id);
        for (regs) |r| {
            const root = pr.region(r).root;
            try self.rewrite(root);
        }
    }

    // -----------------------------------------------------------------
    // β-reduction (hir.md §8.4) — the v1 boundary rewrite
    // -----------------------------------------------------------------

    /// `call(fn_ref-to-λ, args…)` → nested `let`s binding the λ params to
    /// the args, body = the cloned λ body. Contract (hir.md §8.4,
    /// docs/effects.md §10.4): the call result is Copy, the evaluated call
    /// subtree is literally cleanup-free and passes the ownership gate, the
    /// λ body is a seg-safe single expression (`isSegSafe`, not a `seq`
    /// root), and the λ is copied with fresh binders (scope mapping).
    /// Evaluation count and LTR order are structural: β→let evaluates each
    /// argument once, in order, and never deletes, duplicates, or reorders
    /// it — so an argument may carry traps, divergence, `Q`, or observable
    /// effects and is preserved verbatim. `preserves_cleanup` holds because
    /// both the evaluated call subtree (args; the body is deferred) and the
    /// body itself are cleanup-free, with the args staying Copy.
    fn tryBeta(self: *Rewriter, id: hir.ExprId) Error!bool {
        const pr = self.p();
        const n = pr.node(id);
        if (hir.registry.get(n.op).seg != .app) return false;
        const ops = try self.dupOperands(id);
        if (ops.len == 0) return false;

        const callee = ops[0];
        const cn = pr.node(callee);
        if (std.mem.indexOfScalar(u8, hir.registry.get(cn.op).name, '.') != null) return false; // typed op ≠ fn_ref
        if (!std.mem.eql(u8, hir.registry.get(cn.op).name, "fn_ref")) return false;
        const fid = switch (cn.payload) {
            .func => |fr| switch (fr) {
                .func => |f| f,
                .host => return false,
            },
            else => return false,
        };
        if (fid >= self.built.funcs.items.len) return false;
        const rec = self.built.funcs.items[fid];
        if (rec.kind != .lambda) return false;
        if (self.beta_done.contains(fid)) return false;

        // Contract: the argument-independent residue of the call-level
        // island predicate. `isSegSafe(id)` itself is deliberately not used
        // — it also demands the arguments be total and observable-effect-
        // free, which β does not need and would wrongly reject an effectful
        // argument (docs/effects.md §10.4).
        const result_cap = try self.analysis.capabilityOf(n.ty) orelse return false;
        if (result_cap != .copy) return false;
        if (!try self.analysis.cleanupFree(id)) return false;
        if (!try self.analysis.ownershipGate(id)) return false;

        const lambda = pr.node(rec.root);
        if (hir.registry.get(lambda.op).seg != .binder) return false;
        const lam_regs = try self.dupRegions(rec.root);
        if (lam_regs.len != 1) return false;
        const params = try self.dupParams(lam_regs[0]);
        if (ops.len - 1 != params.len) return false;
        const body = pr.region(lam_regs[0]).root;
        if (!try self.analysis.isSegSafe(body)) return false;
        // "single expression" (§8.4): no statement sequence.
        if (std.mem.eql(u8, hir.registry.get(pr.node(body).op).name, "seq")) return false;

        // Arguments stay Copy (a Unique / borrowed argument would change
        // ownership at the synthesized let); their effects are preserved
        // verbatim, so no purity is required. `cleanupFree(id)` above
        // already covers every argument's cleanup and `ownershipGate(id)`
        // its ownership (a `move`/borrow argument leaves `callArgUse` at
        // `.consume`/`.borrow`, which the gate rejects).
        var k: usize = 1;
        while (k < ops.len) : (k += 1) {
            const arg = ops[k];
            const cap = try self.analysis.capabilityOf(pr.node(arg).ty) orelse return false;
            if (cap != .copy) return false;
        }

        // Fresh binders for the λ params (maps_scope), then clone the
        // body with every binder reference remapped (maps_full_expr is
        // identity here: the builder keeps FE 0 for the whole tree).
        var map = std.AutoHashMapUnmanaged(hir.BinderId, hir.BinderId).empty;
        defer map.deinit(self.arena);
        const fresh = try self.arena.alloc(hir.BinderId, params.len);
        for (params, 0..) |pb, j| {
            const b = pr.binder(pb);
            fresh[j] = try pr.addBinder(b.ty, .value);
            try map.put(self.arena, pb, fresh[j]);
        }
        self.clone_fe = n.full_expr;
        const new_body = try self.cloneTree(body, &map);

        // Nested lets, outermost = first parameter (LTR).
        const let_op = hir.opId("let").?;
        var result = new_body;
        var j: usize = params.len;
        while (j > 0) {
            j -= 1;
            const rid = try pr.addRegion(&.{fresh[j]}, result, null);
            const regs = try pr.addRegions(&.{rid});
            const opr = try pr.addOperands(&.{ops[j + 1]});
            result = try pr.addExpr(.{
                .op = let_op,
                .ty = n.ty,
                .operands = opr,
                .regions = regs,
                .full_expr = n.full_expr,
                .sema = try pr.internSema(.owned, .pending),
            });
        }

        // Overwrite the call node in place with the outermost let.
        pr.exprs.items[id] = pr.node(result);
        try self.beta_done.put(self.arena, fid, {});
        return true;
    }

    /// Deep-copy `id`, allocating fresh regions/binders and remapping
    /// every `local` reference through `map` (extended with the fresh
    /// params of each nested region). Used only by β.
    fn cloneTree(self: *Rewriter, id: hir.ExprId, map: *std.AutoHashMapUnmanaged(hir.BinderId, hir.BinderId)) Error!hir.ExprId {
        const pr = self.p();
        const n = pr.node(id);
        const src_ops = try self.dupOperands(id);
        const new_ops = try self.arena.alloc(hir.ExprId, src_ops.len);
        for (src_ops, 0..) |op, i| new_ops[i] = try self.cloneTree(op, map);

        const src_regs = try self.dupRegions(id);
        const new_regs = try self.arena.alloc(hir.RegionId, src_regs.len);
        for (src_regs, 0..) |rid, i| {
            const r = pr.region(rid);
            const src_params = try self.dupParams(rid);
            const new_params = try self.arena.alloc(hir.BinderId, src_params.len);
            for (src_params, 0..) |pb, k| {
                if (map.get(pb)) |mapped| {
                    new_params[k] = mapped;
                } else {
                    const b = pr.binder(pb);
                    new_params[k] = try pr.addBinder(b.ty, b.mode);
                    try map.put(self.arena, pb, new_params[k]);
                }
            }
            const new_root = try self.cloneTree(r.root, map);
            const new_pat: ?hir.PatternId = if (r.pattern) |pid| try self.clonePattern(pid, map) else null;
            new_regs[i] = try pr.addRegion(new_params, new_root, new_pat);
        }

        var nn = n;
        nn.operands = try pr.addOperands(new_ops);
        nn.regions = try pr.addRegions(new_regs);
        nn.full_expr = self.clone_fe;
        nn.sema = try pr.internSema(pr.viewOf(id), .pending);
        if (std.mem.eql(u8, hir.registry.get(n.op).name, "local")) {
            if (map.get(n.payload.binder)) |mapped| nn.payload = .{ .binder = mapped };
        }
        const new_id = try pr.addExpr(nn);
        // A cloned construct owns the same temporaries as its donor: move
        // any cleanup token that named the donor to the clone
        // (docs/effects.md §11.2). β's contract already requires the body
        // to be cleanup-free, so this is a no-op for admitted rewrites;
        // it keeps a token-bearing clone from silently pointing at the
        // unreachable donor.
        pr.remapCleanupOrigin(id, new_id);
        return new_id;
    }

    fn clonePattern(self: *Rewriter, id: hir.PatternId, map: *std.AutoHashMapUnmanaged(hir.BinderId, hir.BinderId)) Error!hir.PatternId {
        const pr = self.p();
        const pat = pr.pattern(id);
        const out: hir.Pattern = switch (pat) {
            .wildcard, .literal => pat,
            .bind => |b| .{ .bind = map.get(b) orelse b },
            .type_test => |tt| .{ .type_test = .{ .ty = tt.ty, .bind = map.get(tt.bind) orelse tt.bind } },
            .tuple => |elems| blk: {
                const new = try self.arena.alloc(hir.PatternId, elems.len);
                for (elems, 0..) |e, i| new[i] = try self.clonePattern(e, map);
                break :blk .{ .tuple = new };
            },
            .list => |lp| blk: {
                const new = try self.arena.alloc(hir.PatternId, lp.elems.len);
                for (lp.elems, 0..) |e, i| new[i] = try self.clonePattern(e, map);
                break :blk .{ .list = .{ .elems = new, .rest = if (lp.rest) |r| try self.clonePattern(r, map) else null } };
            },
            .struct_ => |sp| blk: {
                const new = try self.arena.alloc(hir.Pattern.FieldPattern, sp.fields.len);
                for (sp.fields, 0..) |f, i| new[i] = .{ .field = f.field, .pat = try self.clonePattern(f.pat, map) };
                break :blk .{ .struct_ = .{ .fields = new } };
            },
            .variant => |vp| .{ .variant = .{ .tag = vp.tag, .payload = if (vp.payload) |pld| try self.clonePattern(pld, map) else null } },
        };
        return pr.addPattern(out);
    }

    // -----------------------------------------------------------------
    // Ordinary island rules
    // -----------------------------------------------------------------

    fn applyRules(self: *Rewriter, id: hir.ExprId, allowed: bool) Error!bool {
        if (!allowed) return false;
        const pr = self.p();
        const name = hir.registry.get(pr.node(id).op).name;
        if (std.mem.eql(u8, name, "if") or std.mem.eql(u8, name, "and") or std.mem.eql(u8, name, "or")) {
            if (self.ruleConstCond(id)) {
                self.conds += 1;
                return true;
            }
        }
        if (std.mem.eql(u8, name, "let")) {
            if (try self.ruleLet(id)) {
                self.lets += 1;
                return true;
            }
        }
        if (std.mem.eql(u8, name, "match")) {
            if (try self.ruleMatch(id)) {
                self.matches += 1;
                return true;
            }
        }
        if (hir.registry.get(pr.node(id).op).typed) {
            if (try self.ruleNumeric(id)) return true;
        }
        return false;
    }

    /// `if c then A else B` (also `and`/`or`) with a constant condition
    /// selects the taken branch. Both regions are island members, so the
    /// untaken one is pure and had no observable evaluation to lose.
    fn ruleConstCond(self: *Rewriter, id: hir.ExprId) bool {
        const pr = self.p();
        const ops = pr.operands(id);
        if (ops.len != 1) return false;
        const cond = pr.node(ops[0]);
        if (!std.mem.eql(u8, hir.registry.get(cond.op).name, "const")) return false;
        const taken: usize = switch (cond.payload.const_value) {
            .bool => |b| if (b) 0 else 1,
            else => return false,
        };
        const regs = pr.regionsOf(id);
        if (taken >= regs.len) return false;
        const branch = pr.region(regs[taken]).root;
        pr.exprs.items[id] = pr.node(branch);
        return true;
    }

    /// Known-variant `match` → `let` (hir.md §8.6). When the scrutinee is a
    /// `variant_make` with a statically known tag, dispatch is decided at
    /// compile time: the covering arm (the first variant arm for the tag,
    /// or the first catch-all before it — `hir_lower_control.unionMatch`
    /// coverage) replaces the match, with its pattern leaves bound to the
    /// constructor's payload operands as nested `let`s. Copy-only: the
    /// match reached this rule only as an island member, so `isSegSafe`
    /// already proved the Copy scrutinee, cleanup-free arms and
    /// observable-effect-free region bodies (a consuming/borrowed
    /// scrutinee or an effectful arm never becomes an island member). The
    /// arm's own region params become the new binders, so the body needs
    /// no substitution and no variant pattern is put on a synthesized
    /// `let` (hir.md §5.4).
    fn ruleMatch(self: *Rewriter, id: hir.ExprId) Error!bool {
        const pr = self.p();
        const ops = try self.dupOperands(id);
        if (ops.len != 1) return false;
        const scrut = ops[0];
        const sn = pr.node(scrut);
        if (!std.mem.eql(u8, hir.registry.get(sn.op).name, "variant_make")) return false;
        // The scrutinee's union declaration fixes the tag range and the
        // constructor arity (the HIR validator checks neither).
        const named = switch (sn.ty) {
            .named => |n| n,
            else => return false,
        };
        if (named.id >= self.built.types.len) return false;
        const ud = switch (self.built.types[named.id]) {
            .union_ => |u| u,
            else => return false,
        };
        const tag = sn.payload.tag;
        if (tag >= ud.variants.len) return false;
        const arity = ud.variants[tag].payloads.len;
        const payload_ops = try self.dupOperands(scrut);
        if (payload_ops.len != arity) return false;

        const regs = try self.dupRegions(id);
        for (regs) |rid| {
            const pat = pr.region(rid).pattern orelse return false;
            switch (pr.pattern(pat)) {
                .wildcard => return self.spliceCatchAll(id, rid, null),
                .bind => |b| return self.spliceCatchAll(id, rid, b),
                .variant => |vp| {
                    if (vp.tag >= ud.variants.len) return false;
                    if (vp.tag != tag) continue;
                    return self.spliceVariant(id, rid, vp, payload_ops);
                },
                // A union match admits only variant / catch-all patterns;
                // anything else is malformed and left alone.
                else => return false,
            }
        }
        return false;
    }

    /// A catch-all arm binds the whole scrutinee (`bind`) or discards it
    /// (`wildcard`).
    fn spliceCatchAll(self: *Rewriter, id: hir.ExprId, rid: hir.RegionId, binder: ?hir.BinderId) Error!bool {
        const pr = self.p();
        const params = try self.dupParams(rid);
        if (binder) |b| {
            if (params.len != 1 or params[0] != b) return false;
            const scrut = (try self.dupOperands(id))[0];
            try self.spliceArm(id, &.{b}, &.{scrut}, pr.region(rid).root);
        } else {
            if (params.len != 0) return false;
            pr.exprs.items[id] = pr.node(pr.region(rid).root);
        }
        return true;
    }

    /// A variant arm binds its payload leaves to the constructor's
    /// operands in order. Only `bind` / `wildcard` leaves are admitted —
    /// a nested or refutable pattern cannot be discharged by the outer
    /// tag alone — and an unbound operand is dropped, which island
    /// admission proved unobservable.
    fn spliceVariant(self: *Rewriter, id: hir.ExprId, rid: hir.RegionId, vp: hir.Pattern.VariantPattern, ops: []const hir.ExprId) Error!bool {
        const pr = self.p();
        const params = try self.dupParams(rid);
        const arity = ops.len;
        var binders = std.ArrayListUnmanaged(?hir.BinderId).empty;
        defer binders.deinit(self.arena);
        if (vp.payload) |pp| {
            if (arity == 1) {
                switch (pr.pattern(pp)) {
                    .bind => |b| try binders.append(self.arena, b),
                    .wildcard => try binders.append(self.arena, null),
                    else => return false,
                }
            } else {
                const elems = switch (pr.pattern(pp)) {
                    .tuple => |es| es,
                    else => return false,
                };
                if (elems.len != arity) return false;
                for (elems) |el| {
                    switch (pr.pattern(el)) {
                        .bind => |b| try binders.append(self.arena, b),
                        .wildcard => try binders.append(self.arena, null),
                        else => return false,
                    }
                }
            }
        } else if (arity != 0) {
            return false;
        }
        // The region's params are exactly the materialized binding leaves,
        // in order (the §10.1 leaf/param bijection).
        var k: usize = 0;
        for (binders.items) |b| {
            if (b) |bid| {
                if (k >= params.len or params[k] != bid) return false;
                k += 1;
            }
        }
        if (k != params.len) return false;
        try self.spliceArm(id, binders.items, ops, pr.region(rid).root);
        return true;
    }

    /// Replace the `match` node `id` with
    /// `let b0 = v0 in let b1 = v1 in … body`, skipping `null` binders
    /// (their values are island-safe — total and observable-effect-free —
    /// so dropping the evaluation is unobservable). Nesting is in payload
    /// order (outermost = first), preserving the scrutinee's left-to-right
    /// evaluation (hir.md §5.5).
    fn spliceArm(self: *Rewriter, id: hir.ExprId, binders: []const ?hir.BinderId, values: []const hir.ExprId, body: hir.ExprId) Error!void {
        const pr = self.p();
        std.debug.assert(binders.len == values.len);
        const ty = pr.node(id).ty;
        const fe = pr.node(id).full_expr;
        var result = body;
        var i = binders.len;
        while (i > 0) {
            i -= 1;
            const b = binders[i] orelse continue;
            const rid = try pr.addRegion(&.{b}, result, null);
            const regs = try pr.addRegions(&.{rid});
            const opr = try pr.addOperands(&.{values[i]});
            result = try pr.addExpr(.{
                .op = hir.opId("let").?,
                .ty = ty,
                .operands = opr,
                .regions = regs,
                .full_expr = fe,
                .sema = try pr.internSema(.owned, .pending),
            });
        }
        pr.exprs.items[id] = pr.node(result);
    }

    /// Plain `let` simplification (hir.md §8.3): dead let, used-once
    /// forwarding, and trivial-atom forwarding. All three strictly reduce
    /// `costOf`; the island invariant makes the init discardable (dead)
    /// and the subtree duplicable (forward). A β-generated let may bind an
    /// effectful, non-island init (docs/effects.md §10.4), so the
    /// dead/forward branches additionally require the init to be an island
    /// member (`encOf`) — dropping or moving it would lose or reorder the
    /// effect.
    fn ruleLet(self: *Rewriter, id: hir.ExprId) Error!bool {
        const pr = self.p();
        const ops = pr.operands(id);
        const regs = pr.regionsOf(id);
        if (ops.len != 1 or regs.len != 1) return false;
        const region = pr.region(regs[0]);
        if (region.pattern != null) return false; // destructuring let: no rule
        const params = pr.params(regs[0]);
        if (params.len != 1) return false;
        const bind = params[0];
        const init = ops[0];
        const body = region.root;

        const uses = try self.countUses(body, bind);
        // The island invariant: an island-member init is total and
        // observable-effect-free, so dropping (dead) or forwarding
        // (used-once) its evaluation is unobservable. A β-generated let may
        // instead bind an effectful, non-island argument (docs/effects.md
        // §10.4) — then the init must stay exactly where the call evaluated
        // it. `encOf` is exact for those old argument ids, and true by fiat
        // only for β-clone bodies / match-spliced lets, which are island-safe
        // by construction.
        const init_island = self.encOf(init);
        if (uses == 0) {
            if (!init_island) return false;
            pr.exprs.items[id] = pr.node(body);
            return true;
        }
        if (uses == 1) {
            if (!init_island) return false;
            try self.substOnce(body, bind, init);
            pr.exprs.items[id] = pr.node(body);
            return true;
        }
        if (isTrivialAtom(pr, init)) {
            try self.substAll(body, bind, init);
            pr.exprs.items[id] = pr.node(body);
            return true;
        }
        return false;
    }

    fn countUses(self: *Rewriter, root: hir.ExprId, bind: hir.BinderId) Error!usize {
        const pr = self.p();
        var count: usize = 0;
        var work = std.ArrayListUnmanaged(hir.ExprId).empty;
        defer work.deinit(self.arena);
        try work.append(self.arena, root);
        while (work.pop()) |id| {
            const n = pr.node(id);
            if (std.mem.eql(u8, hir.registry.get(n.op).name, "local") and n.payload.binder == bind) count += 1;
            for (pr.operands(id)) |op| try work.append(self.arena, op);
            for (pr.regionsOf(id)) |r| try work.append(self.arena, pr.region(r).root);
        }
        return count;
    }

    /// Replace the single `local bind` occurrence's *content* with the
    /// init's (a move — the init is only referenced by the let). The let
    /// then becomes `let B = v in body'`; the caller drops the let.
    fn substOnce(self: *Rewriter, root: hir.ExprId, bind: hir.BinderId, init: hir.ExprId) Error!void {
        const pr = self.p();
        var work = std.ArrayListUnmanaged(hir.ExprId).empty;
        defer work.deinit(self.arena);
        try work.append(self.arena, root);
        while (work.pop()) |id| {
            const n = pr.node(id);
            if (std.mem.eql(u8, hir.registry.get(n.op).name, "local") and n.payload.binder == bind) {
                pr.exprs.items[id] = pr.node(init);
                return;
            }
            for (pr.operands(id)) |op| try work.append(self.arena, op);
            for (pr.regionsOf(id)) |r| try work.append(self.arena, pr.region(r).root);
        }
    }

    /// Duplicate a trivial atom (const / local / fn_ref — no regions, no
    /// evaluation) at every use of the binder.
    fn substAll(self: *Rewriter, root: hir.ExprId, bind: hir.BinderId, init: hir.ExprId) Error!void {
        const pr = self.p();
        const atom = pr.node(init);
        var work = std.ArrayListUnmanaged(hir.ExprId).empty;
        defer work.deinit(self.arena);
        try work.append(self.arena, root);
        while (work.pop()) |id| {
            const n = pr.node(id);
            if (std.mem.eql(u8, hir.registry.get(n.op).name, "local") and n.payload.binder == bind) {
                pr.exprs.items[id] = atom;
                continue;
            }
            for (pr.operands(id)) |op| try work.append(self.arena, op);
            for (pr.regionsOf(id)) |r| try work.append(self.arena, pr.region(r).root);
        }
    }

    // -----------------------------------------------------------------
    // Constant folding + integer algebra
    // -----------------------------------------------------------------

    fn ruleNumeric(self: *Rewriter, id: hir.ExprId) Error!bool {
        const pr = self.p();
        const d = hir.registry.get(pr.node(id).op);
        const base = baseName(d.name);
        const rep = d.rep orelse return false;
        const ops = pr.operands(id);

        // Constant folding: every operand a compile-time literal.
        var all_const = true;
        for (ops) |op| {
            if (!std.mem.eql(u8, hir.registry.get(pr.node(op).op).name, "const")) {
                all_const = false;
                break;
            }
        }
        if (all_const and ops.len >= 1 and ops.len <= 2) {
            if (foldNumeric(base, rep, pr, ops)) |value| {
                const ty = pr.node(id).ty;
                pr.exprs.items[id] = .{
                    .op = hir.opId("const").?,
                    .ty = ty,
                    .payload = .{ .const_value = value },
                    .full_expr = pr.node(id).full_expr,
                    .sema = try pr.internSema(.owned, .pending),
                };
                self.folds += 1;
                return true;
            }
        }

        // Integer algebra identities (wrapping reps only).
        if (ops.len == 2 and isIntegerRep(rep)) {
            if (integerAlgebra(base, rep, pr, ops[0], ops[1])) |result| {
                switch (result) {
                    .keep => |idx| pr.exprs.items[id] = pr.node(ops[idx]),
                    .value => |v| pr.exprs.items[id] = .{
                        .op = hir.opId("const").?,
                        .ty = pr.node(id).ty,
                        .payload = .{ .const_value = v },
                        .full_expr = pr.node(id).full_expr,
                        .sema = try pr.internSema(.owned, .pending),
                    },
                }
                self.algebra += 1;
                return true;
            }
        }
        return false;
    }

    /// Minimal-node-count cost (hir.md §8.2's extraction cost): number of
    /// expression nodes in the subtree. The let / folding / algebra rules
    /// strictly reduce it, and the deterministic tie-break is the rule
    /// order in `applyRules` (the v1 rule set has a single candidate per
    /// node); β and the multi-payload `match` reduction are admitted by
    /// their contracts instead (pass header).
    pub fn costOf(self: *Rewriter, root: hir.ExprId) usize {
        return nodeCost(self.p(), root, self.arena);
    }
};

/// Minimal-node-count cost of one subtree (hir.md §8.2). The caller's
/// scratch allocator backs the traversal worklist; the count is
/// returned regardless of allocation failure (the traversal stops).
pub fn nodeCost(program: *hir.Program, root: hir.ExprId, scratch: std.mem.Allocator) usize {
    var count: usize = 0;
    var work = std.ArrayListUnmanaged(hir.ExprId).empty;
    defer work.deinit(scratch);
    work.append(scratch, root) catch return count;
    while (work.pop()) |id| {
        count += 1;
        for (program.operands(id)) |op| work.append(scratch, op) catch return count;
        for (program.regionsOf(id)) |r| work.append(scratch, program.region(r).root) catch return count;
    }
    return count;
}

fn baseName(name: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, name, '.')) |dot| return name[0..dot];
    return name;
}

fn isTrivialAtom(pr: *hir.Program, id: hir.ExprId) bool {
    const name = hir.registry.get(pr.node(id).op).name;
    return std.mem.eql(u8, name, "const") or std.mem.eql(u8, name, "local") or std.mem.eql(u8, name, "fn_ref");
}

fn isIntegerRep(rep: hir.ScalarRep) bool {
    return switch (rep) {
        .i32, .i64, .u32, .u64 => true,
        else => false,
    };
}

// ---------------------------------------------------------------------------
// Constant folding (mirrors cfg_lower_emit's runtime semantics, extended to
// the 64-bit and float reps the HIR registers). A fold that could trap is
// refused: the runtime owns the trap.
// ---------------------------------------------------------------------------

fn constVal(pr: *hir.Program, id: hir.ExprId) meta.ConstValue {
    return pr.node(id).payload.const_value;
}

fn foldNumeric(base: []const u8, rep: hir.ScalarRep, pr: *hir.Program, ops: []const hir.ExprId) ?meta.ConstValue {
    const a = constVal(pr, ops[0]);
    if (ops.len == 1) return foldUnary(base, rep, a);
    const b = constVal(pr, ops[1]);
    return foldBinary(base, rep, a, b);
}

fn foldUnary(base: []const u8, rep: hir.ScalarRep, a: meta.ConstValue) ?meta.ConstValue {
    if (std.mem.eql(u8, base, "neg")) {
        return switch (rep) {
            .i32 => intCV(i32, -%(asInt(i32, a) orelse return null)),
            .i64 => intCV(i64, -%(asInt(i64, a) orelse return null)),
            .u32 => intCV(u32, 0 -% (asInt(u32, a) orelse return null)),
            .u64 => intCV(u64, 0 -% (asInt(u64, a) orelse return null)),
            .f32 => floatCV(f32, -@as(f32, @floatCast(asF64(a) orelse return null))),
            .f64 => floatCV(f64, -(asF64(a) orelse return null)),
            else => null,
        };
    }
    if (std.mem.eql(u8, base, "abs")) {
        return switch (rep) {
            .i32 => blk: {
                const x = asInt(i32, a) orelse return null;
                break :blk intCV(i32, if (x < 0) -%x else x);
            },
            .i64 => blk: {
                const x = asInt(i64, a) orelse return null;
                break :blk intCV(i64, if (x < 0) -%x else x);
            },
            .f32 => floatCV(f32, @abs(@as(f32, @floatCast(asF64(a) orelse return null)))),
            .f64 => floatCV(f64, @abs(asF64(a) orelse return null)),
            else => null, // no unsigned abs (CFG leaves it unfolded too)
        };
    }
    if (std.mem.eql(u8, base, "not")) {
        return switch (a) {
            .bool => |v| .{ .bool = !v },
            else => null,
        };
    }
    if (std.mem.eql(u8, base, "clz")) {
        return switch (rep) {
            .i32 => .{ .int = @clz(@as(u32, @bitCast(asInt(i32, a) orelse return null))) },
            .u32 => .{ .int = @clz(asInt(u32, a) orelse return null) },
            else => null,
        };
    }
    if (std.mem.eql(u8, base, "popcount")) {
        return switch (rep) {
            .i32 => .{ .int = @popCount(@as(u32, @bitCast(asInt(i32, a) orelse return null))) },
            .u32 => .{ .int = @popCount(asInt(u32, a) orelse return null) },
            else => null,
        };
    }
    return null;
}

fn foldBinary(base: []const u8, rep: hir.ScalarRep, a: meta.ConstValue, b: meta.ConstValue) ?meta.ConstValue {
    if (std.mem.eql(u8, base, "add") or std.mem.eql(u8, base, "sub") or
        std.mem.eql(u8, base, "mul") or std.mem.eql(u8, base, "div") or std.mem.eql(u8, base, "rem"))
    {
        return switch (rep) {
            .i32 => intArith(i32, base, a, b),
            .i64 => intArith(i64, base, a, b),
            .u32 => intArith(u32, base, a, b),
            .u64 => intArith(u64, base, a, b),
            .f32 => floatArith(f32, base, a, b),
            .f64 => floatArith(f64, base, a, b),
            else => null,
        };
    }
    if (std.mem.eql(u8, base, "min") or std.mem.eql(u8, base, "max")) {
        const is_min = std.mem.eql(u8, base, "min");
        return switch (rep) {
            .i32 => blk: {
                const x = asInt(i32, a) orelse return null;
                const y = asInt(i32, b) orelse return null;
                break :blk intCV(i32, if (is_min) @min(x, y) else @max(x, y));
            },
            .u32 => blk: {
                const x = asInt(u32, a) orelse return null;
                const y = asInt(u32, b) orelse return null;
                break :blk intCV(u32, if (is_min) @min(x, y) else @max(x, y));
            },
            .f32 => blk: {
                const x: f32 = @floatCast(asF64(a) orelse return null);
                const y: f32 = @floatCast(asF64(b) orelse return null);
                break :blk floatCV(f32, if (is_min) fminIeee(f32, x, y) else fmaxIeee(f32, x, y));
            },
            .f64 => blk: {
                const x = asF64(a) orelse return null;
                const y = asF64(b) orelse return null;
                break :blk floatCV(f64, if (is_min) fminIeee(f64, x, y) else fmaxIeee(f64, x, y));
            },
            else => null,
        };
    }
    if (std.mem.eql(u8, base, "shl") or std.mem.eql(u8, base, "shr")) {
        const is_shl = std.mem.eql(u8, base, "shl");
        return switch (rep) {
            .i32 => intShift(i32, is_shl, a, b),
            .i64 => intShift(i64, is_shl, a, b),
            .u32 => intShift(u32, is_shl, a, b),
            .u64 => intShift(u64, is_shl, a, b),
            else => null,
        };
    }
    if (std.mem.eql(u8, base, "band") or std.mem.eql(u8, base, "bor") or std.mem.eql(u8, base, "bxor")) {
        return switch (rep) {
            .i32 => intBit(i32, base, a, b),
            .i64 => intBit(i64, base, a, b),
            .u32 => intBit(u32, base, a, b),
            .u64 => intBit(u64, base, a, b),
            else => null,
        };
    }
    if (std.mem.eql(u8, base, "eq") or std.mem.eql(u8, base, "ne") or
        std.mem.eql(u8, base, "lt") or std.mem.eql(u8, base, "le") or
        std.mem.eql(u8, base, "gt") or std.mem.eql(u8, base, "ge"))
    {
        return cmpResult(base, rep, a, b);
    }
    return null;
}

fn cmpResult(base: []const u8, rep: hir.ScalarRep, a: meta.ConstValue, b: meta.ConstValue) ?meta.ConstValue {
    const eq = std.mem.eql(u8, base, "eq");
    const ne = std.mem.eql(u8, base, "ne");
    const eq_style = eq or ne;
    const r: bool = switch (rep) {
        .i32 => cmpInt(i32, base, a, b) orelse return null,
        .i64 => cmpInt(i64, base, a, b) orelse return null,
        .u32 => cmpInt(u32, base, a, b) orelse return null,
        .u64 => cmpInt(u64, base, a, b) orelse return null,
        .f32, .f64 => cmpFloat(base, a, b) orelse return null,
        .bool => blk: {
            if (!eq_style) return null;
            const x = asBool(a) orelse return null;
            const y = asBool(b) orelse return null;
            break :blk if (eq) x == y else x != y;
        },
        .str => blk: {
            if (!eq_style) return null;
            const x = asStr(a) orelse return null;
            const y = asStr(b) orelse return null;
            break :blk if (eq) std.mem.eql(u8, x, y) else !std.mem.eql(u8, x, y);
        },
        // `byte` comparisons lower through the u32 family (hir.md §7.2
        // M1a note); the value occupies one host cell, compared unsigned.
        .byte => blk: {
            const x = asInt(u8, a) orelse return null;
            const y = asInt(u8, b) orelse return null;
            if (eq) break :blk x == y;
            if (ne) break :blk x != y;
            if (std.mem.eql(u8, base, "lt")) break :blk x < y;
            if (std.mem.eql(u8, base, "le")) break :blk x <= y;
            if (std.mem.eql(u8, base, "gt")) break :blk x > y;
            break :blk x >= y;
        },
    };
    return .{ .bool = r };
}

fn cmpInt(comptime T: type, base: []const u8, a: meta.ConstValue, b: meta.ConstValue) ?bool {
    const x = asInt(T, a) orelse return null;
    const y = asInt(T, b) orelse return null;
    if (std.mem.eql(u8, base, "eq")) return x == y;
    if (std.mem.eql(u8, base, "ne")) return x != y;
    if (std.mem.eql(u8, base, "lt")) return x < y;
    if (std.mem.eql(u8, base, "le")) return x <= y;
    if (std.mem.eql(u8, base, "gt")) return x > y;
    if (std.mem.eql(u8, base, "ge")) return x >= y;
    return null;
}

fn cmpFloat(base: []const u8, a: meta.ConstValue, b: meta.ConstValue) ?bool {
    const x = asF64(a) orelse return null;
    const y = asF64(b) orelse return null;
    if (std.mem.eql(u8, base, "eq")) return x == y;
    if (std.mem.eql(u8, base, "ne")) return x != y;
    if (std.mem.eql(u8, base, "lt")) return x < y;
    if (std.mem.eql(u8, base, "le")) return x <= y;
    if (std.mem.eql(u8, base, "gt")) return x > y;
    if (std.mem.eql(u8, base, "ge")) return x >= y;
    return null;
}

fn intArith(comptime T: type, base: []const u8, a: meta.ConstValue, b: meta.ConstValue) ?meta.ConstValue {
    const x = asInt(T, a) orelse return null;
    const y = asInt(T, b) orelse return null;
    if (std.mem.eql(u8, base, "add")) return intCV(T, x +% y);
    if (std.mem.eql(u8, base, "sub")) return intCV(T, x -% y);
    if (std.mem.eql(u8, base, "mul")) return intCV(T, x *% y);
    if (y == 0) return null; // division/remainder by zero traps — leave it
    if (comptime @typeInfo(T).int.signedness == .signed) {
        if (x == std.math.minInt(T) and y == -1) {
            // `min / -1` traps for `div`; `min % -1` is exactly 0.
            if (std.mem.eql(u8, base, "div")) return null;
            return intCV(T, 0);
        }
    }
    if (std.mem.eql(u8, base, "div")) return intCV(T, @divTrunc(x, y));
    return intCV(T, @rem(x, y));
}

fn intShift(comptime T: type, is_shl: bool, a: meta.ConstValue, b: meta.ConstValue) ?meta.ConstValue {
    const bits = @typeInfo(T).int.bits;
    const U = std.meta.Int(.unsigned, bits);
    const x = asInt(T, a) orelse return null;
    const y = asInt(T, b) orelse return null;
    const s: std.math.Log2Int(T) = @intCast(@as(U, @bitCast(y)) & (bits - 1));
    if (is_shl) return intCV(T, @bitCast(@as(U, @bitCast(x)) << s));
    return intCV(T, x >> s);
}

fn intBit(comptime T: type, base: []const u8, a: meta.ConstValue, b: meta.ConstValue) ?meta.ConstValue {
    const x = asInt(T, a) orelse return null;
    const y = asInt(T, b) orelse return null;
    if (std.mem.eql(u8, base, "band")) return intCV(T, x & y);
    if (std.mem.eql(u8, base, "bor")) return intCV(T, x | y);
    return intCV(T, x ^ y);
}

fn floatArith(comptime T: type, base: []const u8, a: meta.ConstValue, b: meta.ConstValue) ?meta.ConstValue {
    const x = asF64(a) orelse return null;
    const y = asF64(b) orelse return null;
    if (std.mem.eql(u8, base, "add")) return floatCV(T, @as(T, @floatCast(x)) + @as(T, @floatCast(y)));
    if (std.mem.eql(u8, base, "sub")) return floatCV(T, @as(T, @floatCast(x)) - @as(T, @floatCast(y)));
    if (std.mem.eql(u8, base, "mul")) return floatCV(T, @as(T, @floatCast(x)) * @as(T, @floatCast(y)));
    if (std.mem.eql(u8, base, "div")) return floatCV(T, @as(T, @floatCast(x)) / @as(T, @floatCast(y)));
    // Zig `@rem` on floats is the truncated remainder (fmod).
    return floatCV(T, @rem(@as(T, @floatCast(x)), @as(T, @floatCast(y))));
}

// --- constant-value helpers (meta.ConstValue keeps integers as i64 bit
// patterns) ---------------------------------------------------------------

fn asInt(comptime T: type, c: meta.ConstValue) ?T {
    const U = std.meta.Int(.unsigned, @typeInfo(T).int.bits);
    return switch (c) {
        .int => |i| @bitCast(@as(U, @truncate(@as(u64, @bitCast(i))))),
        else => null,
    };
}

fn asF64(c: meta.ConstValue) ?f64 {
    return switch (c) {
        .float => |f| f,
        else => null,
    };
}

fn asBool(c: meta.ConstValue) ?bool {
    return switch (c) {
        .bool => |b| b,
        else => null,
    };
}

fn asStr(c: meta.ConstValue) ?[]const u8 {
    return switch (c) {
        .string => |s| s,
        else => null,
    };
}

fn intCV(comptime T: type, v: T) meta.ConstValue {
    if (comptime @typeInfo(T).int.signedness == .signed) {
        return .{ .int = v };
    } else {
        return .{ .int = @bitCast(@as(u64, v)) };
    }
}

fn floatCV(comptime T: type, v: T) meta.ConstValue {
    return .{ .float = @floatCast(v) };
}

/// IEEE 754 `fmin`: NaN propagates, `fmin(-0, +0) = -0` (mirrors
/// cfg_lower_emit).
fn fminIeee(comptime T: type, a: T, b: T) T {
    if (std.math.isNan(a) or std.math.isNan(b)) return std.math.nan(T);
    if (a == 0.0 and b == 0.0) return if (std.math.signbit(a)) a else b;
    return if (a < b) a else b;
}

fn fmaxIeee(comptime T: type, a: T, b: T) T {
    if (std.math.isNan(a) or std.math.isNan(b)) return std.math.nan(T);
    if (a == 0.0 and b == 0.0) return if (std.math.signbit(b)) a else b;
    return if (a > b) a else b;
}

// ---------------------------------------------------------------------------
// Integer algebra identities
// ---------------------------------------------------------------------------

const AlgebraResult = union(enum) {
    /// Keep operand `keep` (0 or 1) as the result.
    keep: usize,
    /// The result is this constant (drops both operands).
    value: meta.ConstValue,
};

fn integerAlgebra(base: []const u8, rep: hir.ScalarRep, pr: *hir.Program, l: hir.ExprId, r: hir.ExprId) ?AlgebraResult {
    if (!isIntegerRep(rep)) return null;
    const lc = maybeConst(pr, l);
    const rc = maybeConst(pr, r);
    return switch (rep) {
        .i32 => intAlgebraT(i32, base, lc, rc),
        .i64 => intAlgebraT(i64, base, lc, rc),
        .u32 => intAlgebraT(u32, base, lc, rc),
        .u64 => intAlgebraT(u64, base, lc, rc),
        else => null,
    };
}

fn maybeConst(pr: *hir.Program, id: hir.ExprId) ?meta.ConstValue {
    if (!std.mem.eql(u8, hir.registry.get(pr.node(id).op).name, "const")) return null;
    return pr.node(id).payload.const_value;
}

fn intAlgebraT(comptime T: type, base: []const u8, lc: ?meta.ConstValue, rc: ?meta.ConstValue) ?AlgebraResult {
    const lz = if (lc) |c| (asInt(T, c) orelse return null) == 0 else false;
    const rz = if (rc) |c| (asInt(T, c) orelse return null) == 0 else false;
    const lo = if (lc) |c| (asInt(T, c) orelse return null) == 1 else false;
    const ro = if (rc) |c| (asInt(T, c) orelse return null) == 1 else false;
    const lall = if (lc) |c| (asInt(T, c) orelse return null) == ~@as(T, 0) else false;
    const rall = if (rc) |c| (asInt(T, c) orelse return null) == ~@as(T, 0) else false;

    if (std.mem.eql(u8, base, "add")) {
        if (lz) return .{ .keep = 1 };
        if (rz) return .{ .keep = 0 };
    } else if (std.mem.eql(u8, base, "sub")) {
        if (rz) return .{ .keep = 0 };
    } else if (std.mem.eql(u8, base, "mul")) {
        if (lo) return .{ .keep = 1 };
        if (ro) return .{ .keep = 0 };
        if (lz or rz) return .{ .value = intCV(T, 0) };
    } else if (std.mem.eql(u8, base, "band")) {
        if (lall) return .{ .keep = 1 };
        if (rall) return .{ .keep = 0 };
        if (lz or rz) return .{ .value = intCV(T, 0) };
    } else if (std.mem.eql(u8, base, "bor")) {
        if (lz) return .{ .keep = 1 };
        if (rz) return .{ .keep = 0 };
        if (lall) return .{ .value = intCV(T, ~@as(T, 0)) };
        if (rall) return .{ .value = intCV(T, ~@as(T, 0)) };
    } else if (std.mem.eql(u8, base, "bxor")) {
        if (lz) return .{ .keep = 1 };
        if (rz) return .{ .keep = 0 };
    } else if (std.mem.eql(u8, base, "shl") or std.mem.eql(u8, base, "shr")) {
        if (rz) return .{ .keep = 0 };
    }
    return null;
}

// ---------------------------------------------------------------------------
// White-box tests (hir.md §10.2: owning module `test {}`)
// ---------------------------------------------------------------------------

const testing = std.testing;

test "constant folding covers the 32/64-bit and float reps" {
    try testing.expectEqual(@as(i64, 3), foldBinary("add", .i32, .{ .int = 1 }, .{ .int = 2 }).?.int);
    try testing.expectEqual(@as(i64, 5), foldBinary("add", .i64, .{ .int = 4 }, .{ .int = 1 }).?.int);
    try testing.expectEqual(@as(i64, 6), foldBinary("mul", .u32, .{ .int = 3 }, .{ .int = 2 }).?.int);
    // Integer arithmetic wraps (never traps).
    const wrapped = foldBinary("add", .i32, .{ .int = std.math.maxInt(i32) }, .{ .int = 1 }).?;
    try testing.expectEqual(@as(i64, std.math.minInt(i32)), wrapped.int);
    // Division by zero and signed `min / -1` are left to the runtime.
    try testing.expect(foldBinary("div", .i32, .{ .int = 1 }, .{ .int = 0 }) == null);
    try testing.expect(foldBinary("div", .i64, .{ .int = std.math.minInt(i64) }, .{ .int = -1 }) == null);
    try testing.expectEqual(@as(i64, 0), foldBinary("rem", .i64, .{ .int = std.math.minInt(i64) }, .{ .int = -1 }).?.int);
    // Float division folds (IEEE, never traps).
    const inf = foldBinary("div", .f32, .{ .float = 1.0 }, .{ .float = 0.0 }).?;
    try testing.expect(std.math.isInf(inf.float));
    // Comparisons produce bools.
    try testing.expect(foldBinary("lt", .i32, .{ .int = 1 }, .{ .int = 2 }).?.bool);
    try testing.expect(foldBinary("eq", .str, .{ .string = "a" }, .{ .string = "a" }).?.bool);
    // `byte` has no arithmetic but its comparisons fold unsigned.
    try testing.expect(foldBinary("lt", .byte, .{ .int = 1 }, .{ .int = 2 }).?.bool);
    try testing.expect(!foldBinary("gt", .byte, .{ .int = 1 }, .{ .int = 2 }).?.bool);
    try testing.expect(foldBinary("eq", .byte, .{ .int = 2 }, .{ .int = 2 }).?.bool);
    // A non-comparison byte op has no fold.
    try testing.expect(foldBinary("add", .byte, .{ .int = 1 }, .{ .int = 2 }) == null);
    // Shifts mask the count.
    try testing.expectEqual(@as(i64, std.math.minInt(i32)), foldBinary("shl", .i32, .{ .int = 1 }, .{ .int = 31 }).?.int);
    try testing.expectEqual(@as(i64, 1), foldBinary("shl", .i32, .{ .int = 1 }, .{ .int = 32 }).?.int);
}

test "unary folding: neg wraps, abs clears the sign, not/clz/popcount" {
    try testing.expectEqual(@as(i64, std.math.minInt(i32)), foldUnary("neg", .i32, .{ .int = std.math.minInt(i32) }).?.int);
    try testing.expectEqual(@as(i64, std.math.minInt(i32)), foldUnary("abs", .i32, .{ .int = std.math.minInt(i32) }).?.int);
    try testing.expectEqual(@as(f64, 2.0), foldUnary("abs", .f64, .{ .float = -2.0 }).?.float);
    try testing.expect(foldUnary("not", .bool, .{ .bool = true }).?.bool == false);
    try testing.expectEqual(@as(i64, 32), foldUnary("clz", .u32, .{ .int = 0 }).?.int);
    try testing.expectEqual(@as(i64, 3), foldUnary("popcount", .u32, .{ .int = 0b1011 }).?.int);
    // No unsigned abs (the CFG leaves it unfolded too).
    try testing.expect(foldUnary("abs", .u32, .{ .int = 3 }) == null);
}

test "integer algebra identities are declared, not guessed" {
    const z = meta.ConstValue{ .int = 0 };
    const one = meta.ConstValue{ .int = 1 };
    const allones_i32 = meta.ConstValue{ .int = -1 };
    try testing.expectEqual(@as(usize, 1), intAlgebraT(i32, "add", z, null).?.keep);
    try testing.expectEqual(@as(usize, 0), intAlgebraT(i32, "add", null, z).?.keep);
    try testing.expectEqual(@as(usize, 0), intAlgebraT(i32, "sub", null, z).?.keep);
    try testing.expectEqual(@as(usize, 1), intAlgebraT(i32, "mul", one, null).?.keep);
    try testing.expectEqual(@as(usize, 0), intAlgebraT(i32, "mul", null, one).?.keep);
    try testing.expectEqual(@as(i64, 0), intAlgebraT(i32, "mul", z, null).?.value.int);
    try testing.expectEqual(@as(usize, 1), intAlgebraT(i32, "band", allones_i32, null).?.keep);
    try testing.expectEqual(@as(i64, 0), intAlgebraT(i32, "band", z, null).?.value.int);
    try testing.expectEqual(@as(usize, 1), intAlgebraT(u32, "bor", z, null).?.keep);
    try testing.expectEqual(@as(usize, 0), intAlgebraT(i32, "shl", null, z).?.keep);
    // Float reps take no integer identity.
    try testing.expect(integerAlgebra("add", .f32, undefined, undefined, undefined) == null);
}

test "minimal-node extraction cost counts the subtree" {
    const parse_text = @import("hir_parse.zig").parseText;
    var p = try parse_text("fn (B0: i32) => add.i32(%B0, 0i32)", .{});
    defer p.arena.deinit();
    // lambda + add + local + const
    try testing.expectEqual(@as(usize, 4), nodeCost(&p.program, p.root, testing.allocator));
    // The `add(x, 0) → x` result has strictly smaller cost (the local).
    const add = p.program.region(p.program.regionsOf(p.root)[0]).root;
    try testing.expectEqual(@as(usize, 3), nodeCost(&p.program, add, testing.allocator));
    const lhs = p.program.operands(add)[0];
    try testing.expectEqual(@as(usize, 1), nodeCost(&p.program, lhs, testing.allocator));
}
