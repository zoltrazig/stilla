//! Pass: effect-driven HIR consumers — dead-let and selective
//! A-Normal Form (docs/hir.md §11 M2b, §5.7, §8.3; docs/effects.md §12).
//! In: a built HIR program whose effect annotations are `ready`. Out: the
//! same tree with dead bindings removed and non-floatable operands
//! materialized into `let`s, in place.
//!
//! Both rules are **derived-query driven** (docs/effects.md §12.3: "所有
//! 合法性来自派生查询"): legality is the existing `isDiscardable` /
//! `canFloatAsTree` query, never a `switch(op)` legality table. The pass
//! never inspects an opcode to decide whether a rewrite is legal — it may
//! only *apply* the rule to the `let` / `StrictLTR` shapes the query is
//! evaluated on.
//!
//! - **dead-let** (docs/effects.md §10.2, §12.2): `let B = v in body`
//!   drops the whole `let` when `B` is unused and `isDiscardable(v)`.
//!   The query spans trap / effect / cleanup / ownership, so `10 / y` is
//!   never dropped even though it looks dead.
//! - **selective A-Normal Form** (docs/hir.md §5.7, docs/effects.md
//!   §12.1): for a `StrictLTR` parent, the *first* operand that is not
//!   `canFloatAsTree` is hoisted into `let B = op in parent(…, %B, …)`.
//!   Operands before it are floatable, so leaving them inside the region
//!   keeps LTR intact; the rule is applied one operand per round so the
//!   hoist chain is built from the outside in.
//!
//! **Unique operands transfer or are discarded in place.** A synthesized
//! `let` binding a Unique value is destroyed at the enclosing scope's end,
//! while the original anonymous temporary is destroyed at its
//! full-expression boundary. The rewrite is therefore legal only where
//! the parent already transfers or discards the value, so the synthesized
//! binder's destruction point coincides with the original's (docs/effects
//! .md §11.2, docs/hir.md §5.7):
//!
//! - a `Consume` operand (call argument, aggregate element, `move` /
//!   `drop`) transfers the value to the parent, exactly as the synthesized
//!   local is transferred — nothing is destroyed on either side, so the
//!   full-expression cleanup registration is unchanged;
//! - a statement operand of a sequence (`Class.seq`, every operand but the
//!   forwarded last) is discarded in place, so the synthesized local is
//!   dropped at the same point the anonymous temporary was.
//!
//! A `Read` / `Borrow` operand is never materialized: the original
//! temporary is destroyed at the parent expression's full-expression
//! boundary while the synthesized binder would be destroyed at the
//! enclosing scope end (later).
//!
//! Like SEG (`hir_seg.zig`), the pass re-derives the effect analysis each
//! round and rewrites in place (the HIR is a tree, every node a single
//! parent, arena-append only), and iterates to a **quiet-round fixpoint**:
//! `optimize` runs analysis → rewrite rounds until one reports no change
//! (`Stats.converged`), with no numeric round cap. A round over an unchanged
//! tree re-analyzes to the same conclusions and rewrites nothing, so a quiet
//! round is a true fixpoint; a program that does not quiesce is a hang, not a
//! bound stop.
//!
//! Termination is structural, not budgeted. Each rule moves a strictly
//! finite, monotone resource and no rule recreates another's redex, so the
//! round relation cannot cycle:
//!
//! - **dead-let** removes a `let` node; nothing re-introduces one, and a
//!   removed binding cannot be re-deadened later.
//! - **never-returns suffix deletion** removes an unreachable straight-line
//!   suffix; nothing re-synthesizes it.
//! - **selective ANF** hoists the *first* operand of a `strict_ltr` parent
//!   that is not `canFloatAsTree`. The operands before it remain floatable
//!   and move into their own positions; crucially the synthesized `local`
//!   is itself floatable (`canFloatAsTree(local) == true`), so on the next
//!   round the first-non-floatable index strictly advances. Each parent
//!   therefore admits at most one hoist per operand position — at most
//!   (#operands) hoists — and the per-parent measure is finite.
//!
//! **The ANF termination argument rests on `local` remaining floatable.** If
//! a synthesized `local` ever failed `canFloatAsTree`, the rule would hoist
//! it again as the new first non-floatable operand and loop forever; the
//! derived query is what forbids that, not a counter.
//!
//! The caller re-validates structure and effects afterwards (docs/hir.md
//! §2.4).

const std = @import("std");
const cfg = @import("stilla").cfg;
const meta = @import("stilla").meta;
const hir = @import("stilla").hir;
const moduleinfo = @import("stilla").moduleinfo;
const hir_effects = @import("hir_effects.zig");
const rewrite_contract = @import("rewrite_contract.zig");
const effects = @import("stilla").effects;

pub const Error = hir.Program.InternTypeError;

/// `never` primitive test — the bottom type (Core §13.2).
fn isNeverTy(t: meta.Type) bool {
    return switch (t) {
        .primitive => |k| k == .never,
        else => false,
    };
}

/// dead-let's declared rule (docs/effects.md §10.3–§10.4). The *match*
/// layer stays inline in `tryDeadLet` — the `let` / single non-pattern param
/// / binder-unused shape is structural applicability. What is declared here
/// is legality — the init must be `discardable` (`10 / y` is not: the trap is
/// an effect) — and the contract: the rewrite may discard the init's
/// evaluation, and removing the binding removes its end-of-scope destructor,
/// admissible only under the `binder_destruction` cleanup proof. Both go
/// through the legality engine, which knows requirements, not opcodes.
const dead_let_rule = rewrite_contract.RewriteRule{
    .name = "dead_let",
    .applicability = .shape,
    .legality = &.{.discardable},
    .contract = .{
        .effect = .{ .may_discard = true },
        .preserves_cleanup = .binder_destruction,
    },
};

/// selective ANF's declared rule (docs/effects.md §10.3–§10.4, docs/hir.md
/// §5.7). The *match* layer stays inline in `tryAnf` — the `strict_ltr`
/// policy and the selection of the first non-floatable operand are
/// structural applicability. What is declared here is legality —
/// `evaluation_count_preserved` (hoisting still evaluates the operand
/// exactly once) plus `materializable` (the operands before it may be
/// deferred past it and the hoisted operand's destruction point does not
/// move; `canMaterializeOperand` supplies both, docs/effects.md §12.1) —
/// and the contract: order may change (the preceding operands are
/// floatable, so the reorder is unobservable), nothing is discarded or
/// duplicated. The synthesized `let` is not a fresh boundary (its init
/// keeps the parent's FE), so no `maps_full_expr` / cleanup kind is
/// declared.
const anf_rule = rewrite_contract.RewriteRule{
    .name = "selective_anf",
    .applicability = .shape,
    .legality = &.{ .evaluation_count_preserved, .materializable },
    .contract = .{
        .effect = .{ .preserves_evaluation_count = true, .may_reorder = true },
    },
};

pub const Stats = struct {
    /// Analysis → rewrite rounds actually run.
    iterations: u32 = 0,
    /// `true` when `optimize` exited on a quiet round — the pass reached a
    /// true fixpoint of the current rule set. There is no numeric bound that
    /// can be hit, so a program that never quiesces is a hang, not a bounded
    /// stop.
    converged: bool = false,
    /// Dead `let`s removed.
    dead_lets: usize = 0,
    /// Operands materialized into `let`s.
    hoists: usize = 0,
    /// Unreachable straight-line suffix segments removed after a
    /// never-normalizing head (`never_returns` must fact, docs/effects.md
    /// §10.1): a `seq` suffix operand, or a `let` body after a
    /// never-normalizing initializer.
    suffix_deletions: usize = 0,
};

pub const Config = struct {
    /// The module graph, for the ownership class of generic named types
    /// (same role as in `hir_effects.Config`).
    graph: ?*moduleinfo.ModuleGraph = null,
    /// Embedding host declarations (docs/effects.md §13), passed through
    /// to every internal `hir_effects.Analysis` so the rewrite rounds and
    /// the caller's final re-validation use one effect environment. The
    /// ambient default would be `Top` and silently block optimizations.
    host_decls: []const effects.HostDecl = &.{},
    /// Effect-domain registry (docs/effects.md §5.5–§5.6), passed through
    /// with `host_decls` so the rounds and the re-validation share one
    /// environment.
    resources: effects.ResourceRegistry = .{},
    /// The frozen lattice instance (docs/effects.md §5.7) handed to every
    /// internal `hir_effects.Analysis` so the rounds and the caller's
    /// final re-validation read one instance. Null = the default `flat`
    /// instance over `resources`.
    engine: ?*const effects.Engine = null,
    /// The session's persistent summary cache (docs/effects.md §8.3),
    /// passed through to every internal `hir_effects.Analysis` so the
    /// rounds reuse finalized summaries and re-solve only the SCCs a
    /// rewrite dirtied. Null = a private, never-armed cache (a full solve
    /// every round), leaving direct white-box callers unchanged.
    cache: ?*hir_effects.SummaryCache = null,
    /// Run dead-let elimination.
    dead_let: bool = true,
    /// Run selective A-Normal Form (operand materialization).
    anf: bool = true,
    /// Run `never_returns` straight-line suffix deletion.
    never_suffix: bool = true,
};

/// Apply the M2b consumers to every function body and constant
/// initializer in place, iterating analysis/rewrite to a quiet-round
/// fixpoint. The caller owns `built` and the arena; on return every root
/// is rewritten but not yet re-validated (the caller runs `hir.validate`
/// plus a fresh `Analysis.analyze`/`.validate`). `Stats.converged` records
/// the quiet-round exit; there is no numeric round cap.
pub fn optimize(arena: std.mem.Allocator, built: *hir.BuiltProgram, config: Config) Error!Stats {
    var stats = Stats{};
    while (true) {
        var analysis = try hir_effects.Analysis.init(arena, built, .{ .graph = config.graph, .host_decls = config.host_decls, .resources = config.resources, .engine = config.engine, .cache = config.cache });
        try analysis.analyze();
        var rw = Rewriter{ .arena = arena, .built = built, .analysis = &analysis, .cfg = config };
        const changed = try rw.run();
        stats.iterations += 1;
        stats.dead_lets += rw.dead_lets;
        stats.hoists += rw.hoists;
        stats.suffix_deletions += rw.suffix_deletions;
        if (!changed) {
            stats.converged = true;
            break;
        }
    }
    return stats;
}

const Rewriter = struct {
    arena: std.mem.Allocator,
    built: *hir.BuiltProgram,
    analysis: *hir_effects.Analysis,
    cfg: Config = .{},
    changed: bool = false,
    dead_lets: usize = 0,
    hoists: usize = 0,
    suffix_deletions: usize = 0,
    /// Expressions whose cleanup tokens this round must retire: the
    /// deleted subtrees (unreachable) and every node whose result type
    /// the `never` rule specialized to the bottom type (its registered
    /// temporary can no longer be a live value, and the cleanup-token
    /// validator requires the token's `ty` to agree with its node).
    retire: std.AutoHashMapUnmanaged(hir.ExprId, void) = .empty,
    /// The function whose body the walk is currently rewriting, so a
    /// retire mark can be attributed to its owner (`retireTokens` runs
    /// after the walk). Null while a constant initializer is rewritten.
    cur_fn: ?hir.FuncId = null,
    /// Origins of cleanup tokens still active at the start of this round.
    /// A retire mark for a node with no active token changes no HIR
    /// content (its token was retired in an earlier round), so it must not
    /// mark its function stale.
    active_tokens: std.AutoHashMapUnmanaged(hir.ExprId, void) = .empty,

    fn p(self: *Rewriter) *hir.Program {
        return &self.built.program;
    }

    fn run(self: *Rewriter) Error!bool {
        // Nodes appended by this pass are rewritten only on a later
        // round, when a fresh analysis covers them. Attribute every
        // rewrite to its owning function and mark it stale in the session
        // cache so the next `Analysis.init` re-solves exactly the SCCs
        // whose summaries may have moved (docs/effects.md §8.3).
        //
        // `self.changed` is a monotone round-level flag for the return
        // value, so it is reset per function: a single cumulative flag
        // would mark only the first function that changed and silently
        // skip every later one. Constant initializers are not
        // dependency-graph nodes (constants only contribute drop-type
        // *existence*, handled automatically), so they are not marked.
        for (self.p().cleanup_tokens.items) |tk| {
            if (tk.origin_expr != hir.no_expr) try self.active_tokens.put(self.arena, tk.origin_expr, {});
        }
        var any_changed = false;
        for (self.built.funcs.items, 0..) |rec, i| {
            self.cur_fn = @intCast(i);
            self.changed = false;
            try self.rewrite(rec.root);
            if (self.changed) {
                any_changed = true;
                try self.analysis.cache.markFunctionDirty(self.cur_fn.?);
            }
        }
        self.cur_fn = null;
        for (self.built.consts.items) |c| {
            self.changed = false;
            if (c.init) |root| try self.rewrite(root);
            if (self.changed) any_changed = true;
        }
        self.retireTokens();
        return any_changed;
    }

    /// Copy the operand/region/param id lists into arena-owned slices
    /// before any work that may append to the program's flat buffers (the
    /// same hazard `hir_seg` documents: `operands`/`regionsOf`/`params`
    /// are views into growable buffers).
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

    /// Recursive descent. Rule decisions are taken on the pre-order node
    /// using the current round's analysis; a rewrite replaces the node's
    /// content in place, so parent slots need no update.
    fn rewrite(self: *Rewriter, id: hir.ExprId) Error!void {
        // The `never` rule owns a node on the never-normalizing spine:
        // its result is the bottom type, part of its operand list may be
        // gone, and the value-producing rules (dead-let / ANF) do not
        // apply to a value that never materializes. Recurse into the
        // post-rewrite children only.
        if (self.cfg.never_suffix and try self.neverSuffix(id)) {
            try self.recurse(id);
            return;
        }
        // Try the rules first, while `id`'s operand annotations are still
        // the ones the analysis derived this round.
        if (self.cfg.dead_let and try self.tryDeadLet(id)) {
            self.changed = true;
            self.dead_lets += 1;
            return;
        }
        if (self.cfg.anf and try self.tryAnf(id)) {
            self.changed = true;
            self.hoists += 1;
            return;
        }
        try self.recurse(id);
    }

    /// Descend into a node's current operands and region roots (read
    /// after any in-place rewrite, so a truncated `seq` or a `let`
    /// replaced by its initializer visits only the surviving children).
    fn recurse(self: *Rewriter, id: hir.ExprId) Error!void {
        const ops = try self.dupOperands(id);
        for (ops) |op| try self.rewrite(op);
        const regs = try self.dupRegions(id);
        for (regs) |r| try self.rewrite(self.p().region(r).root);
    }

    // -----------------------------------------------------------------
    // `never_returns` suffix deletion (docs/effects.md §10.1)
    // -----------------------------------------------------------------

    /// The `never_returns` suffix rule. An expression that never completes
    /// normally has no value, so its result type is the bottom type and
    /// the straight-line suffix *after* the failing head is unreachable.
    ///
    /// Returns true when `id` is on the never-normalizing spine, having
    /// specialized its result type to `never` and, where the spine is a
    /// straight-line region, deleted the dead suffix:
    ///
    /// - `seq(o0 … oi …)`: truncate at the first operand `oi` that never
    ///   normalizes (`never_returns`); `oi+1 ..` never run. Operands
    ///   before `oi` still execute and are kept.
    /// - `let B = init in body` with a never-normalizing `init`: the body
    ///   is dead; the node takes the initializer's content.
    ///
    /// Deleting a straight-line suffix can never change behavior — the
    /// head never returns, so the suffix never executes — and the deleted
    /// region's full-expression cleanup is retired with it. Retiring a
    /// token whose node type just became `never` is required hygiene: the
    /// value can no longer own a live temporary, and the cleanup-token
    /// validator requires the token's `ty` to agree with its node.
    fn neverSuffix(self: *Rewriter, id: hir.ExprId) Error!bool {
        if (!try self.analysis.exprNever(id)) return false;
        const pr = self.p();
        const name = hir.registry.get(pr.node(id).op).name;
        if (std.mem.eql(u8, name, "seq")) {
            const ops = try self.dupOperands(id);
            var first: ?usize = null;
            for (ops, 0..) |op, i| {
                if (try self.analysis.exprNever(op)) {
                    first = i;
                    break;
                }
            }
            if (first) |i| {
                if (i + 1 < ops.len) {
                    for (ops[i + 1 ..]) |dead| {
                        try self.markRetireTree(dead);
                        self.suffix_deletions += 1;
                    }
                    pr.exprs.items[id].operands = try pr.addOperands(ops[0 .. i + 1]);
                    self.changed = true;
                }
            }
        } else if (std.mem.eql(u8, name, "let")) {
            const ops = try self.dupOperands(id);
            const regs = try self.dupRegions(id);
            if (ops.len == 1 and regs.len == 1 and try self.analysis.exprNever(ops[0])) {
                // The initializer never returns: the body (and the
                // binder's destructor) is unreachable. Move the
                // initializer's content into this node; the initializer
                // node is orphaned and its tokens retired.
                try self.markRetireTree(pr.region(regs[0]).root);
                try self.markRetire(ops[0]);
                self.suffix_deletions += 1;
                pr.exprs.items[id] = pr.node(ops[0]);
                self.changed = true;
            }
        }
        if (!isNeverTy(pr.typeOf(pr.node(id).ty))) {
            pr.exprs.items[id].ty = try pr.intern(.{ .primitive = .never });
            self.changed = true;
        }
        try self.markRetire(id);
        return true;
    }

    fn markRetire(self: *Rewriter, id: hir.ExprId) Error!void {
        try self.retire.put(self.arena, id, {});
        // Retiring an *active* token changes the owning function's
        // cleanup summary even when no structural rewrite touched its body
        // this round (e.g. `neverSuffix` on a node whose type was already
        // `never`), so mark the owner explicitly rather than relying on
        // `self.changed` (docs/effects.md §8.3). A node with no active
        // token was retired in an earlier round: `retireTokens` is then a
        // no-op and the function need not be re-solved.
        if (self.cur_fn) |fid| {
            if (self.active_tokens.contains(id)) try self.analysis.cache.markFunctionDirty(fid);
        }
    }

    /// Mark a whole deleted subtree for token retirement.
    fn markRetireTree(self: *Rewriter, root: hir.ExprId) Error!void {
        var work = std.ArrayListUnmanaged(hir.ExprId).empty;
        defer work.deinit(self.arena);
        try work.append(self.arena, root);
        while (work.pop()) |id| {
            if (self.retire.contains(id)) continue;
            try self.markRetire(id);
            const pr = self.p();
            for (pr.operands(id)) |op| try work.append(self.arena, op);
            for (pr.regionsOf(id)) |r| try work.append(self.arena, pr.region(r).root);
        }
    }

    /// Retire the round's marked cleanup tokens (docs/effects.md §11.2).
    fn retireTokens(self: *Rewriter) void {
        if (self.retire.count() == 0) return;
        for (self.p().cleanup_tokens.items) |*tk| {
            if (tk.origin_expr == hir.no_expr) continue;
            if (self.retire.contains(tk.origin_expr)) tk.origin_expr = hir.no_expr;
        }
    }

    // -----------------------------------------------------------------
    // dead-let (docs/effects.md §10.2, §12.2)
    // -----------------------------------------------------------------

    fn tryDeadLet(self: *Rewriter, id: hir.ExprId) Error!bool {
        const pr = self.p();
        if (!std.mem.eql(u8, hir.registry.get(pr.node(id).op).name, "let")) return false;
        const ops = try self.dupOperands(id);
        if (ops.len != 1) return false;
        const regs = try self.dupRegions(id);
        if (regs.len != 1) return false;
        const region = pr.region(regs[0]);
        if (region.pattern != null) return false; // destructuring let: not this rule
        const params = try self.dupParams(regs[0]);
        if (params.len != 1) return false;
        const bind = params[0];
        if (try self.countUses(region.root, bind) != 0) return false;
        // Removing a Unique binding also removes its end-of-scope
        // destructor (docs/effects.md §11.2). Block the rewrite unless
        // the binding's destruction is itself discardable in the
        // modelled cleanup model; Copy bindings have no destructor.
        const bind_ty = pr.typeOf(pr.binder(bind).ty);
        if (!try rewrite_contract.checkCleanup(dead_let_rule, self.analysis, .{ .binder_destruction = bind_ty })) return false;
        // Legality is the declared rule's derived query alone — no opcode
        // knowledge.
        if (!try rewrite_contract.check(self.analysis, dead_let_rule.legality, .{ .expr = ops[0] })) return false;
        pr.exprs.items[id] = pr.node(region.root);
        // The result's value now lives at the region root; move any
        // cleanup token that named the `let` node with it (docs/effects.md
        // §11.2 origin remap). `registration_index` is untouched. The
        // binder's own end-of-scope destructor is gone with it: retire
        // its `scope_end` token.
        pr.remapCleanupOrigin(id, region.root);
        pr.retireScopeTokens(bind);
        return true;
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

    // -----------------------------------------------------------------
    // selective A-Normal Form (docs/hir.md §5.7, docs/effects.md §12.1)
    // -----------------------------------------------------------------

    fn tryAnf(self: *Rewriter, id: hir.ExprId) Error!bool {
        const pr = self.p();
        const n = pr.node(id);
        // EvalPolicy is the language semantics of the parent: only an
        // eager StrictLTR op has its operands' order fixed by the
        // operand sequence. (This is the descriptor's policy, not an
        // opcode table.)
        if (hir.registry.get(n.op).policy != .strict_ltr) return false;
        const ops = try self.dupOperands(id);
        if (ops.len == 0) return false;
        for (ops, 0..) |op, k| {
            // Preceding operands may stay inside the region only if they
            // can float as trees (total, no observable effect, cleanup
            // free); otherwise they would have been the first hit.
            if (try self.analysis.canFloatAsTree(op)) continue;
            // The first non-floatable operand: hoisting it keeps LTR,
            // because every earlier operand is floatable. Its legality is
            // the declared rule's derived query (`canMaterializeOperand`):
            // the earlier operands are deferrable and the hoisted
            // operand's destruction point does not move.
            const slot: u32 = @intCast(k);
            if (!try rewrite_contract.check(self.analysis, anf_rule.legality, .{ .hoist = .{ .parent = id, .slot = slot } })) return false;
            try self.hoist(id, k, ops);
            return true;
        }
        return false;
    }

    /// `parent(…, op_k, …)` → `let B = op_k in parent(…, %B, …)`, with the
    /// parent's region range kept intact for the inner node and the outer
    /// node overwritten in place with the new `let`.
    fn hoist(self: *Rewriter, id: hir.ExprId, k: usize, ops: []const hir.ExprId) Error!void {
        const pr = self.p();
        const n = pr.node(id);
        const arg = ops[k];
        const arg_ty = pr.node(arg).ty;

        const fresh = try pr.addBinder(pr.typeOf(arg_ty), .value);
        const local = try pr.addExpr(.{
            .op = hir.opId("local").?,
            .ty = arg_ty,
            .payload = .{ .binder = fresh },
            .full_expr = n.full_expr,
            .sema = try pr.internSema(.owned, .pending),
        });

        const new_ops = try self.arena.dupe(hir.ExprId, ops);
        new_ops[k] = local;
        var inner_node = n;
        inner_node.operands = try pr.addOperands(new_ops);
        inner_node.sema = try pr.internSema(pr.viewOf(id), .pending);
        const inner = try pr.addExpr(inner_node);

        const rid = try pr.addRegion(&.{fresh}, inner, null);
        pr.exprs.items[id] = .{
            .op = hir.opId("let").?,
            .ty = n.ty,
            .operands = try pr.addOperands(&.{arg}),
            .regions = try pr.addRegions(&.{rid}),
            .full_expr = n.full_expr,
            .origin = n.origin,
            .sema = try pr.internSema(.owned, .pending),
        };
        // The original construct (and any cleanup token naming it) now
        // lives at the synthesized inner node (docs/effects.md §11.2
        // origin remap); the hoisted `arg` node keeps its identity and
        // registration index.
        pr.remapCleanupOrigin(id, inner);
    }
};

// ---------------------------------------------------------------------------
// White-box tests (docs/hir.md §10.2: owning module `test {}`)
// ---------------------------------------------------------------------------

const testing = std.testing;
const hir_build = @import("hir_build.zig");
const checker = @import("stilla").checker;

const Fixture = struct {
    arena: *std.heap.ArenaAllocator,
    built: *hir.BuiltProgram,
    graph: *moduleinfo.ModuleGraph,

    fn deinit(self: *Fixture) void {
        self.arena.deinit();
    }
};

fn build(entry: []const u8, texts: []const struct { []const u8, []const u8 }) !Fixture {
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
    const graph = builder.build(entry) catch return error.Diagnostic;
    var ck = checker.Checker.init(alloc);
    _ = ck.check(graph) catch return error.Diagnostic;
    var bdiag: moduleinfo.Diag = undefined;
    const built = hir_build.buildProgramDiag(alloc, graph, &ck.annotation, &bdiag) catch return error.Diagnostic;
    return .{ .arena = arena, .built = built, .graph = graph };
}

fn funcBody(f: *Fixture, name: []const u8) ?hir.ExprId {
    for (f.built.funcs.items) |rec| {
        if (std.mem.eql(u8, rec.name, name)) {
            const root = rec.root;
            return f.built.program.region(f.built.program.regionsOf(root)[0]).root;
        }
    }
    return null;
}

fn opName(p: *hir.Program, id: hir.ExprId) []const u8 {
    return hir.registry.get(p.node(id).op).name;
}

/// The rewritten program still validates structurally and its effects
/// re-derive soundly (docs/hir.md §2.4).
fn expectRewrittenValid(f: *Fixture) !void {
    for (f.built.funcs.items) |rec| {
        if (try hir.validate(&f.built.program, rec.root, testing.allocator)) |m| {
            defer testing.allocator.free(m);
            std.debug.print("post-simplify validate failed: {s}\n", .{m});
            return error.TestUnexpectedResult;
        }
    }
    var an = try hir_effects.Analysis.init(f.arena.allocator(), f.built, .{ .graph = f.graph });
    try an.analyze();
    if (try an.validate(testing.allocator)) |m| {
        defer testing.allocator.free(m);
        std.debug.print("post-simplify effect validation failed: {s}\n", .{m});
        return error.TestUnexpectedResult;
    }
}

test "hir_simplify: dead let with a discardable init is removed" {
    var f = try build("app", &.{.{
        "app",
        \\fn pure(x: int32) -> int32 { x + 1 }
        \\fn f(x: int32) -> int32 {
        \\    let unused: int32 = pure(x);
        \\    7
        \\}
    }});
    defer f.deinit();
    const stats = try optimize(f.arena.allocator(), f.built, .{ .graph = f.graph });
    try testing.expect(stats.dead_lets > 0);
    try expectRewrittenValid(&f);
    const body = funcBody(&f, "app.f").?;
    try testing.expect(!std.mem.eql(u8, opName(&f.built.program, body), "let"));
}

test "hir_simplify: a trapping division is not dropped as dead" {
    var f = try build("app", &.{.{
        "app",
        \\fn f(y: int32) -> int32 {
        \\    let unused: int32 = 10 / y;
        \\    0
        \\}
    }});
    defer f.deinit();
    const stats = try optimize(f.arena.allocator(), f.built, .{ .graph = f.graph });
    try testing.expectEqual(@as(usize, 0), stats.dead_lets);
    // The `div.i32` node is still reachable.
    var found = false;
    for (f.built.program.exprs.items, 0..) |e, i| {
        if (std.mem.eql(u8, hir.registry.get(e.op).name, "div.i32")) found = true;
        _ = i;
    }
    try testing.expect(found);
    try expectRewrittenValid(&f);
}

test "hir_simplify: ANF hoists the first non-floatable operand in LTR order" {
    var f = try build("app", &.{.{
        "app",
        \\const builtin = import("builtin");
        \\fn pure(x: int32) -> int32 { x * 2 }
        \\fn f(x: int32) -> int32 {
        \\    pure(1) + builtin.hash(x)
        \\}
    }});
    defer f.deinit();
    _ = try optimize(f.arena.allocator(), f.built, .{ .graph = f.graph });
    try expectRewrittenValid(&f);
    // The body root is now a `let` whose init is the quoted host call and
    // whose region body is the original `add.i32` with a `local` in the
    // second operand slot.
    const body = funcBody(&f, "app.f").?;
    const pr = &f.built.program;
    try testing.expect(std.mem.eql(u8, opName(pr, body), "let"));
    const init = pr.operands(body)[0];
    try testing.expect(std.mem.eql(u8, opName(pr, init), "call"));
    const inner = pr.region(pr.regionsOf(body)[0]).root;
    try testing.expect(std.mem.eql(u8, opName(pr, inner), "add.i32"));
    const ops = pr.operands(inner);
    try testing.expect(std.mem.eql(u8, opName(pr, ops[1]), "local"));
}

test "hir_simplify: ANF materializes a Unique operand the parent transfers" {
    var f = try build("app", &.{.{
        "app",
        \\const builtin = import("builtin");
        \\struct Token { id: int32; drop(t) { builtin.print(builtin.str(t.id)); } }
        \\fn make(id: int32) -> Token {
        \\    builtin.print("make");
        \\    Token { id: id }
        \\}
        \\fn take(move t: Token) -> int32 { t.id }
        \\fn f(x: int32) -> int32 {
        \\    take(make(x))
        \\}
    }});
    defer f.deinit();
    const stats = try optimize(f.arena.allocator(), f.built, .{ .graph = f.graph });
    try testing.expect(stats.hoists >= 1);
    try expectRewrittenValid(&f);
    // `take(make(x))` → `let B = make(x) in take(%B)`: the synthesized
    // binder is transferred to the call exactly as the anonymous
    // temporary was, so nothing is destroyed at the let's scope end.
    const body = funcBody(&f, "app.f").?;
    const pr = &f.built.program;
    try testing.expect(std.mem.eql(u8, opName(pr, body), "let"));
    const init = pr.operands(body)[0];
    try testing.expect(std.mem.eql(u8, opName(pr, init), "call"));
    const inner = pr.region(pr.regionsOf(body)[0]).root;
    try testing.expect(std.mem.eql(u8, opName(pr, inner), "call"));
    try testing.expect(std.mem.eql(u8, opName(pr, pr.operands(inner)[1]), "local"));
    // The temporary stays transferred: no cleanup token names the
    // synthesized local or the forwarded call's argument, and the
    // synthesized binder carries no `scope_end` token (its rewrite
    // contract proves the parent transfers the value, docs/effects.md
    // §11.2).
    const synth_binder = pr.params(pr.regionsOf(body)[0])[0];
    for (pr.cleanup_tokens.items) |tk| {
        if (tk.origin_expr == hir.no_expr) continue;
        try testing.expect(!std.mem.eql(u8, opName(pr, tk.origin_expr), "local"));
        switch (tk.kind) {
            .full_expression => {},
            .scope_end => |se| try testing.expect(se.binder != synth_binder),
        }
    }
}

test "hir_simplify: ANF does not materialize a Unique operand the parent only borrows" {
    var f = try build("app", &.{.{
        "app",
        \\const builtin = import("builtin");
        \\struct Token { id: int32; drop(t) { builtin.print("bye"); } }
        \\fn make(id: int32) -> Token { Token { id: id } }
        \\fn show(borrow t: Token) -> int32 { t.id }
        \\fn f(x: int32) -> int32 {
        \\    show(make(x))
        \\}
    }});
    defer f.deinit();
    const stats = try optimize(f.arena.allocator(), f.built, .{ .graph = f.graph });
    _ = stats; // unrelated `seq`/`call` hoists in the hook body are counted too
    try expectRewrittenValid(&f);
    // `f`'s operand stays in place: the parent only borrows it, so the
    // temporary is still destroyed at `f`'s full-expression boundary.
    const body = funcBody(&f, "app.f").?;
    const pr = &f.built.program;
    try testing.expect(std.mem.eql(u8, opName(pr, body), "call"));
    try testing.expect(std.mem.eql(u8, opName(pr, pr.operands(body)[1]), "call"));
}

test "hir_simplify: ANF materializes a discarded Unique statement in place" {
    var f = try build("app", &.{.{
        "app",
        \\const builtin = import("builtin");
        \\struct Token { id: int32; drop(t) { builtin.print(builtin.str(t.id)); } }
        \\fn make(id: int32) -> Token { Token { id: id } }
        \\fn f(x: int32) -> int32 {
        \\    make(x);
        \\    7
        \\}
    }});
    defer f.deinit();
    const stats = try optimize(f.arena.allocator(), f.built, .{ .graph = f.graph });
    try testing.expect(stats.hoists >= 1);
    try expectRewrittenValid(&f);
    // `make(x); 7` → `let B = make(x) in seq(%B, 7)`: the sequence
    // discards `%B` at the statement point, so the destructor fires
    // exactly where the anonymous temporary's did.
    const body = funcBody(&f, "app.f").?;
    const pr = &f.built.program;
    try testing.expect(std.mem.eql(u8, opName(pr, body), "let"));
    try testing.expect(std.mem.eql(u8, opName(pr, pr.operands(body)[0]), "call"));
    const inner = pr.region(pr.regionsOf(body)[0]).root;
    try testing.expect(std.mem.eql(u8, opName(pr, inner), "seq"));
    try testing.expect(std.mem.eql(u8, opName(pr, pr.operands(inner)[0]), "local"));
}

/// Count the nodes with op `want` in the subtree rooted at `root`.
fn countOp(p: *hir.Program, root: hir.ExprId, want: []const u8) usize {
    var count: usize = 0;
    var work = std.ArrayListUnmanaged(hir.ExprId).empty;
    defer work.deinit(testing.allocator);
    work.append(testing.allocator, root) catch return count;
    while (work.pop()) |id| {
        if (std.mem.eql(u8, hir.registry.get(p.node(id).op).name, want)) count += 1;
        for (p.operands(id)) |op| work.append(testing.allocator, op) catch return count;
        for (p.regionsOf(id)) |r| work.append(testing.allocator, p.region(r).root) catch return count;
    }
    return count;
}

test "hir_simplify: a structurally-never call deletes its straight-line suffix" {
    // `boom` is declared `void`, so the builder keeps the suffix after the
    // call (`isNever` never fires); the `never_returns` must fact deletes
    // `print("dead"); x + 1`, keeping the earlier statement.
    var f = try build("app", &.{.{
        "app",
        \\const builtin = import("builtin");
        \\fn boom() -> void { builtin.panic("x") }
        \\fn f(x: int32) -> int32 {
        \\    builtin.print("before");
        \\    boom();
        \\    builtin.print("dead");
        \\    x + 1
        \\}
    }});
    defer f.deinit();
    const stats = try optimize(f.arena.allocator(), f.built, .{ .graph = f.graph });
    try testing.expect(stats.suffix_deletions >= 1);
    try expectRewrittenValid(&f);
    const body = funcBody(&f, "app.f").?;
    const pr = &f.built.program;
    // The dead arithmetic and the dead print call are gone; the earlier
    // statement and the never call survive.
    try testing.expectEqual(@as(usize, 0), countOp(pr, body, "add.i32"));
    // The earlier `print("before")` and the `boom()` call survive; the
    // deleted `print("dead")` does not.
    try testing.expectEqual(@as(usize, 2), countOp(pr, body, "call"));
    try testing.expect(neverTy(pr, body));
}

test "hir_simplify: a never-normalizing let initializer deletes the body" {
    // The builder's statement shortcut does not look at a `let`
    // initializer: `let x = boom()` keeps the rest of the block. The
    // never rule replaces the `let` with its initializer and drops the
    // body.
    var f = try build("app", &.{.{
        "app",
        \\const builtin = import("builtin");
        \\fn boom() -> void { builtin.panic("x") }
        \\fn f(x: int32) -> int32 {
        \\    let y = boom();
        \\    builtin.print("dead");
        \\    x + 1
        \\}
    }});
    defer f.deinit();
    const stats = try optimize(f.arena.allocator(), f.built, .{ .graph = f.graph });
    try testing.expect(stats.suffix_deletions >= 1);
    try expectRewrittenValid(&f);
    const body = funcBody(&f, "app.f").?;
    const pr = &f.built.program;
    // The `let` collapsed to the call, and the body is gone.
    try testing.expect(std.mem.eql(u8, opName(pr, body), "call"));
    try testing.expectEqual(@as(usize, 0), countOp(pr, body, "add.i32"));
    try testing.expect(neverTy(pr, body));
}

test "hir_simplify: a normal-returning callee keeps its suffix" {
    var f = try build("app", &.{.{
        "app",
        \\const builtin = import("builtin");
        \\fn ok() -> void { builtin.print("ok"); }
        \\fn f() -> int32 {
        \\    ok();
        \\    builtin.print("kept");
        \\    7
        \\}
    }});
    defer f.deinit();
    const stats = try optimize(f.arena.allocator(), f.built, .{ .graph = f.graph });
    // No straight-line suffix is ever deleted: `ok` has a normal return
    // path, so nothing after it is unreachable.
    try testing.expectEqual(@as(usize, 0), stats.suffix_deletions);
    try expectRewrittenValid(&f);
    // Both prints survive (the `f` body prints twice, `ok` prints once).
    const body = funcBody(&f, "app.f").?;
    try testing.expectEqual(@as(usize, 2), countOp(&f.built.program, body, "call"));
}

fn neverTy(p: *hir.Program, id: hir.ExprId) bool {
    return switch (p.typeOf(p.node(id).ty)) {
        .primitive => |k| k == .never,
        else => false,
    };
}

test "hir_simplify: dead_let toggle keeps a discardable dead let" {
    var f = try build("app", &.{.{
        "app",
        \\fn pure(x: int32) -> int32 { x + 1 }
        \\fn f(x: int32) -> int32 {
        \\    let unused: int32 = pure(x);
        \\    7
        \\}
    }});
    defer f.deinit();
    const stats = try optimize(f.arena.allocator(), f.built, .{ .graph = f.graph, .dead_let = false });
    try testing.expectEqual(@as(usize, 0), stats.dead_lets);
    try expectRewrittenValid(&f);
    const body = funcBody(&f, "app.f").?;
    try testing.expect(std.mem.eql(u8, opName(&f.built.program, body), "let"));
}

test "hir_simplify: anf toggle keeps the first non-floatable operand in place" {
    var f = try build("app", &.{.{
        "app",
        \\const builtin = import("builtin");
        \\fn pure(x: int32) -> int32 { x * 2 }
        \\fn f(x: int32) -> int32 {
        \\    pure(1) + builtin.hash(x)
        \\}
    }});
    defer f.deinit();
    const stats = try optimize(f.arena.allocator(), f.built, .{ .graph = f.graph, .anf = false });
    try testing.expectEqual(@as(usize, 0), stats.hoists);
    try expectRewrittenValid(&f);
    const body = funcBody(&f, "app.f").?;
    try testing.expect(std.mem.eql(u8, opName(&f.built.program, body), "add.i32"));
}

test "hir_simplify: never_suffix toggle keeps the unreachable suffix" {
    var f = try build("app", &.{.{
        "app",
        \\const builtin = import("builtin");
        \\fn boom() -> void { builtin.panic("x") }
        \\fn f(x: int32) -> int32 {
        \\    builtin.print("before");
        \\    boom();
        \\    builtin.print("dead");
        \\    x + 1
        \\}
    }});
    defer f.deinit();
    const stats = try optimize(f.arena.allocator(), f.built, .{ .graph = f.graph, .never_suffix = false });
    try testing.expectEqual(@as(usize, 0), stats.suffix_deletions);
    try expectRewrittenValid(&f);
    const body = funcBody(&f, "app.f").?;
    try testing.expect(countOp(&f.built.program, body, "add.i32") >= 1);
}

test "hir_simplify: default Config still applies all three rewrites" {
    {
        var f = try build("app", &.{.{
            "app",
            \\fn pure(x: int32) -> int32 { x + 1 }
            \\fn f(x: int32) -> int32 {
            \\    let unused: int32 = pure(x);
            \\    7
            \\}
        }});
        defer f.deinit();
        const stats = try optimize(f.arena.allocator(), f.built, .{ .graph = f.graph });
        try testing.expect(stats.dead_lets > 0);
    }
    {
        var f = try build("app", &.{.{
            "app",
            \\const builtin = import("builtin");
            \\fn pure(x: int32) -> int32 { x * 2 }
            \\fn f(x: int32) -> int32 {
            \\    pure(1) + builtin.hash(x)
            \\}
        }});
        defer f.deinit();
        const stats = try optimize(f.arena.allocator(), f.built, .{ .graph = f.graph });
        try testing.expect(stats.hoists > 0);
    }
    {
        var f = try build("app", &.{.{
            "app",
            \\const builtin = import("builtin");
            \\fn boom() -> void { builtin.panic("x") }
            \\fn f(x: int32) -> int32 {
            \\    builtin.print("before");
            \\    boom();
            \\    builtin.print("dead");
            \\    x + 1
            \\}
        }});
        defer f.deinit();
        const stats = try optimize(f.arena.allocator(), f.built, .{ .graph = f.graph });
        try testing.expect(stats.suffix_deletions > 0);
    }
}
