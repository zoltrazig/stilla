//! Pass: HIR effect analysis — docs/hir.md §6.2/§10.1 level two and
//! docs/effects.md §6–§12 (M1b: effect infrastructure). In: a built HIR
//! program (`hir_build.buildProgram`). Out: every reachable node carries a
//! `ready` interned `EffectSummary`, plus the legality queries the M2
//! consumers will drive.
//!
//! M1b scope (docs/hir.md §11, docs/effects.md §14):
//!
//! - **Transfer** (docs/effects.md §6.1) composes each node's summary from
//!   its descriptor (`OpDescriptor.own_effect` + `TransferKind`) and its
//!   operands/regions: `strict_ltr`, `let`, `branch`, `match`, `call`,
//!   `lambda` creation, `drop`, `module_const` read, and the base-type
//!   dependent `field_get`.
//! - **Function summaries** propagate through **direct** calls only, by
//!   DFS. A recursive dependency (a callee already on the visit stack)
//!   yields conservative `Top`, which propagates to callers; the SCC
//!   least fixpoint of docs/effects.md §8.2 is **M2b**, not here. Missing
//!   bodies, indirect targets, and undeclared host effects are `Top`
//!   (docs/effects.md §9.1/§9.3/§13).
//! - **Pending / Ready** (docs/effects.md §8.2, §10.5) is outside the
//!   lattice. Every query fails closed while a fact is pending; only
//!   `Ready` facts may justify a transform.
//! - **Cleanup** (docs/effects.md §11) has two paths. The literal
//!   `cleanupFree` proof (every executed node Copy, no owned Unique
//!   region binding, no `drop`) still gates β / speculatability /
//!   reorder. The full-expression footprint (`cleanupEffect`) consumes
//!   the `CleanupToken`s registered by the builder's cleanup pass
//!   (`passes/hir_build_cleanup.zig`): `observedEffect` and
//!   `canFloatAsTree` fold `drop_effect(T)` over the subtree's tokens in
//!   reverse creation order. An unmodelled program
//!   (`Program.cleanup_modeled` unset) or a subtree owning a Unique region
//!   binding yields `null` → `Top`: an empty token table is never a proof
//!   of safety.
//! - **Derived queries** (docs/effects.md §10.1) combine effects with
//!   operand uses, result capability/view, and ownership/lifetime gates.
//!   The *semantic* SEG-safety predicate (`isSegSafe`) is separate from
//!   encoding support (`hasSegEncoding`, all false until M2a) — admission
//!   needs both.
//!
//! This pass does **not** transform the HIR and does not touch the CFG:
//! annotations are additive metadata, so canonical printing and the
//! lowered AIR stay identical. `modules`-level concerns deferred to M2b:
//! the SCC fixpoint, module-const init/teardown summary checks, and the
//! exact drop planner.

const std = @import("std");
const meta = @import("stilla").meta;
const hir = @import("stilla").hir;
const moduleinfo = @import("stilla").moduleinfo;
const effects = @import("stilla").effects;

const hir_effects_summary = @import("hir_effects_summary.zig");
const hir_effects_never = @import("hir_effects_never.zig");
const hir_effects_drop = @import("hir_effects_drop.zig");
const hir_effects_const = @import("hir_effects_const.zig");
const hir_effects_queries = @import("hir_effects_queries.zig");
const hir_effects_cache = @import("hir_effects_cache.zig");

pub const Summary = effects.Summary;
pub const Error = std.mem.Allocator.Error;
pub const SummaryCache = hir_effects_cache.SummaryCache;

pub const lambda_op = hir.opId("lambda").?;
pub const fn_ref_op = hir.opId("fn_ref").?;
pub const call_op = hir.opId("call").?;
pub const drop_op = hir.opId("drop").?;
pub const let_op = hir.opId("let").?;
pub const local_op = hir.opId("local").?;
pub const if_op = hir.opId("if").?;
pub const match_op = hir.opId("match").?;
pub const seq_op = hir.opId("seq").?;
pub const move_op = hir.opId("move").?;
pub const borrow_op = hir.opId("borrow").?;

/// Precision budget for indirect-call target narrowing (docs/effects.md
/// §9.2). Exceeding either bound makes resolution *unprovable*, not
/// approximate: the call site falls back to `Top`. Truncating to the
/// first N targets would under-approximate the summary, which is a
/// soundness bug, so the budget is never a cut-off point for the set.
pub const max_indirect_targets: usize = 8;
pub const max_indirect_steps: usize = 64;

/// One statically-resolved indirect-call target (docs/effects.md §9.2).
/// Only the two *finite* target kinds are representable: a Stilla
/// function record and a host binding. An inline λ node cannot reach
/// call position from source (the builder hoists every source λ to a
/// `fn_ref` to a `FuncKind.lambda` record), so `resolveTargets` has no λ
/// case; `effectBound` / `callbackBound` keep their λ fast path for
/// white-box callers.
pub const ResolvedTarget = union(enum) {
    func: hir.FuncId,
    host: hir.HostBindingId,
};

/// Optional external facts (docs/effects.md §13). A host binding with no
/// declaration is the full `Top`; `host_decls` carries the embedding's
/// symbol-keyed attestations, `hosts` the id-keyed form white-box tests
/// use. An empty table therefore makes every host call `Top`.
pub const Config = struct {
    hosts: effects.HostEffects = .{},
    /// Symbol-keyed host declarations (docs/effects.md §13) — the
    /// embedder-facing ABI form, resolved against `built.hosts` at setup
    /// and merged ahead of `hosts`. White-box callers that already hold
    /// `HostBindingId`s use `hosts` directly.
    host_decls: []const effects.HostDecl = &.{},
    resources: effects.ResourceRegistry = .{},
    /// The frozen lattice instance (docs/effects.md §5.7). A session
    /// (`frontend.compile`) interns one and threads it here so every
    /// consumer reads the same instance; when null the analysis interns
    /// its own default `flat` instance over `resources`.
    engine: ?*const effects.Engine = null,
    /// The module graph, used only to resolve the ownership class of
    /// generic named type instantiations. Without it, such a type is
    /// conservatively Unique.
    graph: ?*moduleinfo.ModuleGraph = null,
    /// The session's persistent summary cache (docs/effects.md §8.3).
    /// When null the analysis allocates a private, never-armed cache, so
    /// every solve is a full re-derivation — the behavior is byte-for-
    /// byte the pre-incremental one. A supplied cache lets successive
    /// `Analysis` instances reuse finalized summaries and re-solve only
    /// the SCCs a rewrite dirtied.
    cache: ?*SummaryCache = null,
};

/// The function-summary driver's state (docs/effects.md §8.2). `cur`
/// holds the in-progress least-fixpoint approximation for the SCC being
/// solved; `summary` holds the finalized summaries. A callee in the SCC
/// currently being solved reads `cur`, every other callee reads
/// `summary` (callee-first SCC order makes that a finalized fact).
pub const Analysis = struct {
    arena: std.mem.Allocator,
    built: *hir.BuiltProgram,
    config: Config,
    /// The frozen lattice instance every composition and query goes
    /// through (docs/effects.md §5.7). A session passes one in; a
    /// white-box caller's analysis interns its own.
    eng: effects.Engine,
    /// The resolved host table: symbol-keyed ABI declarations folded with
    /// the id-keyed entries of `config.hosts`, one entry per binding.
    hosts: effects.HostEffects,
    /// Per-node memo of the transfer result (analysis scratch, not the
    /// annotation; the summary driver clears it per fixpoint round so a
    /// round is a simultaneous update from one approximation).
    memo: []?Summary,
    /// Finalized per-function summaries.
    summary: []Summary,
    /// Whether `summary[fid]` holds a finalized value.
    known: []bool,
    /// The SCC each function belongs to (index into the driver's list).
    comp_of: []u32,
    /// The SCC currently being solved, if any.
    solving: ?u32,
    /// The in-progress approximation for the SCC in `solving`.
    cur: []Summary,
    /// Unified dependency-graph nodes (docs/effects.md §11.1): ids
    /// `0..F-1` are functions, `F` is the reserved `Top` sink, and
    /// `F+1..` are `drop_type` nodes keyed by canonical `HIRTypeId`.
    /// `drop_node_of` maps a type key to its node; `drop_key_of_node`
    /// is the inverse (only meaningful at `>= F+1`; placeholders
    /// elsewhere). `summary` / `known` / `cur` / `comp_of` grow to the
    /// full node count when the graph is solved.
    drop_node_of: std.AutoHashMapUnmanaged(hir.HIRTypeId, u32) = .empty,
    drop_key_of_node: std.ArrayList(hir.HIRTypeId) = .empty,
    /// The reserved `Top`-summary sink materialized when a drop-type
    /// descent exceeds the depth safety net.
    top_sink_node: u32 = 0,
    /// Binder → its `let` initializer (docs/effects.md §9.2): the local
    /// fn-ref propagation index. `hir.no_expr` for every binder that is
    /// not bound by a plain single-identifier `let` — a function / λ
    /// parameter, a match-arm or destructuring binding — where
    /// `resolveTargets` stops and the call site falls back to `Top`.
    binder_init: []hir.ExprId,
    /// The must fact `never_returns(f)` (docs/effects.md §10.1), derived
    /// by `computeNeverReturns`. Read only through `neverReturns` /
    /// `exprNever`, which compute it lazily.
    never_returns: []bool,
    /// Per-node memo for `exprNeverTree`, valid under one fixed
    /// `never_returns` approximation (the gfp clears it per round).
    never_memo: []?bool,
    never_computed: bool = false,
    /// The persistent summary cache this analysis solves against
    /// (docs/effects.md §8.3). A caller-supplied cache arms and is reused
    /// incrementally; a private one never arms, keeping the default path
    /// full-solve.
    cache: *SummaryCache,
    /// Whether `cache` was supplied by the caller. The private default
    /// cache is a sink only: it never arms, so every solve is full.
    incremental: bool,

    pub fn init(arena: std.mem.Allocator, built: *hir.BuiltProgram, config: Config) Error!Analysis {
        const memo = try arena.alloc(?Summary, built.program.exprs.items.len);
        @memset(memo, null);
        const cache = if (config.cache) |c| c else try SummaryCache.init(arena);
        const incremental = config.cache != null;
        var summary = try arena.alloc(Summary, built.funcs.items.len);
        @memset(summary, effects.pure);
        var known = try arena.alloc(bool, built.funcs.items.len);
        @memset(known, false);
        var comp_of = try arena.alloc(u32, built.funcs.items.len);
        @memset(comp_of, 0);
        var cur = try arena.alloc(Summary, built.funcs.items.len);
        @memset(cur, effects.pure);
        // Seed the working arrays from an armed cache: the incremental
        // solve starts from the last finalized values and only re-solves
        // the SCCs a rewriter dirtied.
        var drop_node_of: std.AutoHashMapUnmanaged(hir.HIRTypeId, u32) = .empty;
        var drop_key_of_node: std.ArrayList(hir.HIRTypeId) = .empty;
        var top_sink_node: u32 = 0;
        if (incremental and cache.armed and cache.summary.len > 0) {
            const n = cache.summary.len;
            summary = try arena.alloc(Summary, n);
            @memcpy(summary, cache.summary);
            known = try arena.alloc(bool, n);
            @memcpy(known, cache.known);
            comp_of = try arena.alloc(u32, n);
            @memset(comp_of, 0);
            cur = try arena.alloc(Summary, n);
            @memset(cur, effects.pure);
            try drop_key_of_node.appendSlice(arena, cache.drop_key_of_node.items);
            var it = cache.drop_node_of.iterator();
            while (it.next()) |e| try drop_node_of.put(arena, e.key_ptr.*, e.value_ptr.*);
            top_sink_node = cache.top_sink_node;
        }
        // The local fn-ref propagation index (docs/effects.md §9.2): one
        // pass over the node store mapping a plain `let`'s single binder
        // to the initializer it is bound to. Destructuring lets
        // (`pattern != null`) and every other region kind stay `no_expr`.
        const binder_init = try arena.alloc(hir.ExprId, built.program.binders.items.len);
        @memset(binder_init, hir.no_expr);
        for (built.program.exprs.items, 0..) |e, i| {
            if (e.op != let_op) continue;
            const ops = built.program.operands(@intCast(i));
            if (ops.len != 1) continue;
            const regs = built.program.regionsOf(@intCast(i));
            if (regs.len != 1) continue;
            if (built.program.region(regs[0]).pattern != null) continue;
            const params = built.program.params(regs[0]);
            if (params.len != 1) continue;
            binder_init[params[0]] = ops[0];
        }
        // Resolve the symbol-keyed ABI declarations against this
        // program's bindings, then fold in the id-keyed entries some
        // white-box callers pass. `consolidate` makes a conflicting
        // duplicate degrade to `top` instead of depending on order.
        const keys = try arena.alloc(effects.HostDeclKey, built.hosts.items.len);
        for (built.hosts.items, 0..) |hb, i| keys[i] = .{ .key = hb.key, .id = @intCast(i) };
        const abi = try effects.HostEffects.resolve(arena, config.host_decls, keys);
        const merged = try effects.HostEffects.consolidate(
            arena,
            try std.mem.concat(arena, effects.HostEffects.Entry, &.{ abi.entries, config.hosts.entries }),
        );
        const eng: effects.Engine = if (config.engine) |e| e.* else try effects.Engine.initDefault(arena, config.resources);
        return .{
            .arena = arena,
            .built = built,
            .config = config,
            .eng = eng,
            .hosts = merged,
            .memo = memo,
            .summary = summary,
            .known = known,
            .comp_of = comp_of,
            .solving = null,
            .cur = cur,
            .drop_node_of = drop_node_of,
            .drop_key_of_node = drop_key_of_node,
            .top_sink_node = top_sink_node,
            .cache = cache,
            .incremental = incremental,
            .binder_init = binder_init,
            .never_returns = blk: {
                const nr = try arena.alloc(bool, built.funcs.items.len);
                @memset(nr, false);
                break :blk nr;
            },
            .never_memo = blk: {
                const nm = try arena.alloc(?bool, built.program.exprs.items.len);
                @memset(nm, null);
                break :blk nm;
            },
        };
    }

    pub fn p(self: *Analysis) *hir.Program {
        return &self.built.program;
    }

    // -----------------------------------------------------------------
    // Annotation driver
    // -----------------------------------------------------------------

    /// Compute every function summary (the SCC least fixpoint of
    /// docs/effects.md §8.2), then annotate every reachable node
    /// (function bodies and module-constant initializers) with its
    /// interned `ready` summary. Idempotent.
    pub fn analyze(self: *Analysis) Error!void {
        // The hard cross-instance binding (docs/effects.md §5.7):
        // interning happens here, so this is the point where the table
        // binds. A second analysis of this program under a *different*
        // lattice instance wipes the previous rows and re-derives every
        // annotation — the old rows are dead weight, not facts.
        try self.p().effect_interner.ensureInstance(self.eng.descriptor_digest);
        try self.solveSummaries();
        for (self.built.funcs.items) |rec| try self.annotateTree(rec.root);
        for (self.built.consts.items) |c| {
            if (c.init) |root| try self.annotateTree(root);
        }
    }

    fn annotateTree(self: *Analysis, root: hir.ExprId) Error!void {
        var work = std.ArrayListUnmanaged(hir.ExprId).empty;
        defer work.deinit(self.arena);
        try work.append(self.arena, root);
        while (work.pop()) |cur| {
            const s = try self.effectOf(cur);
            const sid = try self.p().effect_interner.summaryId(s);
            try self.p().setEffect(cur, .{ .ready = sid });
            const pr = self.p();
            for (pr.operands(cur)) |op| try work.append(self.arena, op);
            for (pr.regionsOf(cur)) |r| try work.append(self.arena, pr.region(r).root);
        }
    }

    /// Validate stored annotations against a fresh derivation
    /// (docs/hir.md §10.1, M1b level). Returns null when every reachable
    /// node is `ready` and `derived ≤ stored` (a sound over-
    /// approximation, including `Top`), or the first violation message,
    /// owned by `allocator`. A `pending` annotation and an out-of-range
    /// summary id are violations; an under-approximation (derived ⊄
    /// stored) is rejected.
    pub fn validate(self: *Analysis, allocator: std.mem.Allocator) Error!?[]const u8 {
        // Re-derive everything through the same transfer logic: clear the
        // per-node memo *first*, then re-run the SCC least fixpoint so
        // every function summary is recomputed from scratch (docs/effects
        // .md §8.2/§8.3). Reusing the prior fixpoint would let the check
        // compare an annotation against itself.
        try self.solveSummaries();
        for (self.built.funcs.items) |rec| {
            if (try self.validateTree(rec.root, rec.name, allocator)) |msg| return msg;
        }
        for (self.built.consts.items) |c| {
            if (c.init) |root| {
                if (try self.validateTree(root, c.key, allocator)) |msg| return msg;
            }
        }
        return null;
    }

    fn validateTree(self: *Analysis, root: hir.ExprId, label: []const u8, allocator: std.mem.Allocator) Error!?[]const u8 {
        var work = std.ArrayListUnmanaged(hir.ExprId).empty;
        defer work.deinit(self.arena);
        try work.append(self.arena, root);
        while (work.pop()) |cur| {
            const sid = switch (self.p().effectOf(cur)) {
                .pending => {
                    const msg = try std.fmt.allocPrint(allocator, "node {d} in '{s}': effect annotation is still pending (M1b requires every reachable node ready)", .{ cur, label });
                    return msg;
                },
                .ready => |id| id,
            };
            if (sid >= self.p().effect_interner.summaries.items.len) {
                const msg = try std.fmt.allocPrint(allocator, "node {d} in '{s}': effect summary id {d} is out of range", .{ cur, label, sid });
                return msg;
            }
            const stored = self.p().effect_interner.summary(sid);
            const derived = try self.effectOf(cur);
            if (!derived.le(stored)) {
                const msg = try std.fmt.allocPrint(allocator, "node {d} in '{s}': stored effect summary is not a sound over-approximation of the derived summary", .{ cur, label });
                return msg;
            }
            const pr = self.p();
            for (pr.operands(cur)) |op| try work.append(self.arena, op);
            for (pr.regionsOf(cur)) |r| try work.append(self.arena, pr.region(r).root);
        }
        return null;
    }

    /// Whether matching `pid` can trap. Only list patterns do: their
    /// element access lowers to bounds-checked `read_index` (borrowed) or
    /// `split_list` (owned), both `may_trap` in `cfg.opInfo`. Every other
    /// pattern kind (wildcard/bind/literal/tuple/struct/variant/type
    /// test) is total. The HIR carries no node for the pattern, so the
    /// `let_`/`match` transfers must account for it here (docs/effects.md
    /// §14 hidden-operation audit).
    fn patternMayTrap(self: *Analysis, pid: hir.PatternId) bool {
        return switch (self.p().pattern(pid)) {
            .wildcard, .bind, .literal, .type_test => false,
            .list => true,
            .tuple => |subs| self.anyPatternMayTrap(subs),
            .struct_ => |sp| blk: {
                for (sp.fields) |f| {
                    if (self.patternMayTrap(f.pat)) break :blk true;
                }
                break :blk false;
            },
            .variant => |vp| if (vp.payload) |sub| self.patternMayTrap(sub) else false,
        };
    }

    fn anyPatternMayTrap(self: *Analysis, pids: []const hir.PatternId) bool {
        for (pids) |pid| {
            if (self.patternMayTrap(pid)) return true;
        }
        return false;
    }

    /// The `eval_effect` of a node — never implicitly attached to the
    /// current full expression's cleanup (that is `observedEffect`).
    pub fn effectOf(self: *Analysis, id: hir.ExprId) Error!Summary {
        if (self.memo[id]) |s| return s;
        const s = try self.compute(id);
        self.memo[id] = s;
        return s;
    }

    fn compute(self: *Analysis, id: hir.ExprId) Error!Summary {
        const pr = self.p();
        const e = pr.node(id);
        // A value-position module chain (`lib.math.sqrt`) is lowered as
        // `module_ref` + per-hop `load_member` (hir.md §7.4), and a
        // `module_ref` can trigger module initialization — an effect this
        // model does not represent. The leaf's own spec effect (`fn_ref`
        // is Pure, §7.3) therefore cannot stand; use `Top` (docs/effects.md
        // §14 audit note). Call-position host/intrinsic leaves carry no
        // hops, so ordinary direct calls are unaffected.
        if (e.access_hops.len > 0) return self.eng.top();
        const d = hir.registry.get(e.op);
        switch (d.transfer) {
            .atom => return d.own_effect,
            .lambda => return d.own_effect,
            .strict_ltr => {
                var acc = d.own_effect;
                for (pr.operands(id)) |op| {
                    acc = try self.eng.sequence(acc, try self.effectOf(op));
                }
                return acc;
            },
            .field_get => {
                var acc = self.fieldGetOwn(id);
                for (pr.operands(id)) |op| {
                    acc = try self.eng.sequence(acc, try self.effectOf(op));
                }
                return acc;
            },
            .let_ => {
                var acc = d.own_effect;
                for (pr.operands(id)) |op| {
                    acc = try self.eng.sequence(acc, try self.effectOf(op));
                }
                for (pr.regionsOf(id)) |r| {
                    // The region's pattern is not an HIR node: a list
                    // pattern's element reads (`read_index`/`split_list`,
                    // cfg may_trap) must be sequenced here explicitly.
                    if (pr.region(r).pattern) |pt| {
                        if (self.patternMayTrap(pt)) acc = try self.eng.sequence(acc, effects.may_trap);
                    }
                    acc = try self.eng.sequence(acc, try self.effectOf(pr.region(r).root));
                }
                return acc;
            },
            .branch => {
                // if / and / or: cond first, then one of two lazy regions.
                var acc = d.own_effect;
                var alt = effects.pure;
                for (pr.operands(id)) |op| {
                    acc = try self.eng.sequence(acc, try self.effectOf(op));
                }
                for (pr.regionsOf(id)) |r| {
                    alt = try self.eng.join(alt, try self.effectOf(pr.region(r).root));
                }
                return self.eng.sequence(acc, alt);
            },
            .match => {
                var acc = d.own_effect;
                var arms = effects.pure;
                for (pr.operands(id)) |op| {
                    acc = try self.eng.sequence(acc, try self.effectOf(op));
                }
                for (pr.regionsOf(id)) |r| {
                    // An arm's pattern test precedes its body: sequence the
                    // may-trap (list patterns) explicitly rather than
                    // joining it. Values coincide today (may-formula), but
                    // the semantic role is sequence (docs/effects.md §5.4).
                    var arm = effects.pure;
                    if (pr.region(r).pattern) |pt| {
                        if (self.patternMayTrap(pt)) arm = try self.eng.sequence(arm, effects.may_trap);
                    }
                    arm = try self.eng.sequence(arm, try self.effectOf(pr.region(r).root));
                    arms = try self.eng.join(arms, arm);
                }
                return self.eng.sequence(acc, arms);
            },
            .call => {
                const ops = pr.operands(id);
                var acc = d.own_effect;
                if (ops.len > 0) {
                    acc = try self.eng.sequence(acc, try self.effectOf(ops[0]));
                    for (ops[1..]) |arg| {
                        acc = try self.eng.sequence(acc, try self.effectOf(arg));
                    }
                    acc = try self.eng.sequence(acc, try self.callBound(ops));
                }
                return acc;
            },
            .drop_effect => {
                var acc = d.own_effect;
                const ops = pr.operands(id);
                if (ops.len > 0) {
                    acc = try self.eng.sequence(acc, try self.dropEffectOf(pr.typeOf(pr.node(ops[0]).ty)));
                    acc = try self.eng.sequence(acc, try self.effectOf(ops[0]));
                }
                return acc;
            },
            .module_const => {
                const cid = switch (e.payload) {
                    .module_const => |c| c,
                    else => return self.eng.top(),
                };
                var raw = [_]effects.EffectAccess{.{
                    .resource = .{ .module_const = cid },
                    .mode = .read,
                }};
                return self.eng.summaryOf(&raw);
            },
        }
    }

    /// `field_get` own effect. The lowering maps it to `read_field`
    /// (nominal struct) or `read_tuple` (tuple element) — both total and
    /// effect-free (`cfg.opInfo`). A list base lowers to a bounds-checked
    /// `read_index`: it is `Top` unless the base is a `list_make` whose
    /// statically-known length proves the payload index in range (the
    /// bounds proof the projection rule consumes, hir.md §8.3). Any other
    /// base type is not a valid `field_get` (the lowering rejects it), so
    /// it is conservatively `Top` rather than assumed pure.
    fn fieldGetOwn(self: *Analysis, id: hir.ExprId) Summary {
        const pr = self.p();
        const ops = pr.operands(id);
        if (ops.len == 0) return self.eng.top();
        return switch (pr.typeOf(pr.node(ops[0]).ty)) {
            .named, .tuple => effects.pure,
            // A list index read lowers to a bounds-checked `read_index`
            // and may trap (docs/effects.md §14 hidden-operation audit).
            // A `list_make` base with the payload index inside its
            // operand list is the one shape whose length is statically
            // known, so the read is provably in range and cannot trap —
            // the bounds proof the projection rule consumes (hir.md
            // §8.3). Any other list base keeps the conservative `Top`.
            .list => blk: {
                if (!std.mem.eql(u8, hir.registry.get(pr.node(ops[0]).op).name, "list_make")) break :blk self.eng.top();
                if (@as(usize, pr.node(id).payload.field) >= pr.operands(ops[0]).len) break :blk self.eng.top();
                break :blk effects.pure;
            },
            else => self.eng.top(),
        };
    }
    // -----------------------------------------------------------------
    // Moved seam methods. The bodies live in the seam files imported at
    // the top of this file; these aliases keep `an.<method>(...)` call
    // syntax identical for every consumer, inside this struct and outside.
    // -----------------------------------------------------------------
    pub const effectBound = hir_effects_summary.effectBound;
    pub const targetBound = hir_effects_summary.targetBound;
    pub const hostSummary = hir_effects_summary.hostSummary;
    pub const resolveTargets = hir_effects_summary.resolveTargets;
    pub const addTarget = hir_effects_summary.addTarget;
    pub const callBound = hir_effects_summary.callBound;
    pub const targetCallBound = hir_effects_summary.targetCallBound;
    pub const callbackBound = hir_effects_summary.callbackBound;
    pub const functionSummary = hir_effects_summary.functionSummary;
    pub const nodeValue = hir_effects_summary.nodeValue;
    pub const nodeTransfer = hir_effects_summary.nodeTransfer;
    pub const solveSummaries = hir_effects_summary.solveSummaries;
    pub const collectCallees = hir_effects_summary.collectCallees;
    pub const collectCallableTarget = hir_effects_summary.collectCallableTarget;
    pub const solveComponent = hir_effects_summary.solveComponent;
    pub const recordBodySummary = hir_effects_summary.recordBodySummary;
    pub const moduleHasStorage = hir_effects_summary.moduleHasStorage;
    pub const lambdaBodySummary = hir_effects_summary.lambdaBodySummary;
    pub const neverReturns = hir_effects_never.neverReturns;
    pub const exprNever = hir_effects_never.exprNever;
    pub const ensureNeverComputed = hir_effects_never.ensureNeverComputed;
    pub const computeNeverReturns = hir_effects_never.computeNeverReturns;
    pub const exprNeverTree = hir_effects_never.exprNeverTree;
    pub const neverMemoAt = hir_effects_never.neverMemoAt;
    pub const exprNeverOfNode = hir_effects_never.exprNeverOfNode;
    pub const callTargetsNever = hir_effects_never.callTargetsNever;
    pub const hostNeverReturns = hir_effects_never.hostNeverReturns;
    pub const dropEffectOf = hir_effects_drop.dropEffectOf;
    pub const dropEffectFree = hir_effects_drop.dropEffectFree;
    pub const dropSummary = hir_effects_drop.dropSummary;
    pub const dropNodeTransfer = hir_effects_drop.dropNodeTransfer;
    pub const addDropNode = hir_effects_drop.addDropNode;
    pub const collectFunctionDrops = hir_effects_drop.collectFunctionDrops;
    pub const collectConstDrops = hir_effects_drop.collectConstDrops;
    pub const checkModuleDependencies = hir_effects_const.checkModuleDependencies;
    pub const checkInitReads = hir_effects_const.checkInitReads;
    pub const checkTeardownReads = hir_effects_const.checkTeardownReads;
    pub const typeIsNominal = hir_effects_const.typeIsNominal;
    pub const checkReadSet = hir_effects_const.checkReadSet;
    pub const readDiag = hir_effects_const.readDiag;
    pub const attributingCallee = hir_effects_const.attributingCallee;
    pub const initOrderOf = hir_effects_const.initOrderOf;
    pub const isCopyType = hir_effects_const.isCopyType;
    pub const findFuncByName = hir_effects_const.findFuncByName;
    pub const hostRelease = hir_effects_const.hostRelease;
    pub const capabilityOf = hir_effects_queries.capabilityOf;
    pub const declModule = hir_effects_queries.declModule;
    pub const operandUseOf = hir_effects_queries.operandUseOf;
    pub const capabilityUse = hir_effects_queries.capabilityUse;
    pub const callArgUse = hir_effects_queries.callArgUse;
    pub const cleanupFree = hir_effects_queries.cleanupFree;
    pub const regionOwnsUnique = hir_effects_queries.regionOwnsUnique;
    pub const ownershipGate = hir_effects_queries.ownershipGate;
    pub const readySummary = hir_effects_queries.readySummary;
    pub const observedEffect = hir_effects_queries.observedEffect;
    pub const cleanupEffect = hir_effects_queries.cleanupEffect;
    pub const cleanupDiscardable = hir_effects_queries.cleanupDiscardable;
    pub const bindingCleanupDiscardable = hir_effects_queries.bindingCleanupDiscardable;
    pub const isTotal = hir_effects_queries.isTotal;
    pub const observableEffectFree = hir_effects_queries.observableEffectFree;
    pub const canFloatAsTree = hir_effects_queries.canFloatAsTree;
    pub const isDiscardable = hir_effects_queries.isDiscardable;
    pub const isDuplicable = hir_effects_queries.isDuplicable;
    pub const isSegSafe = hir_effects_queries.isSegSafe;
    pub const hasSegEncoding = hir_effects_queries.hasSegEncoding;
    pub const isSegAdmissible = hir_effects_queries.isSegAdmissible;
    pub const isIntrinsicallySpeculatable = hir_effects_queries.isIntrinsicallySpeculatable;
    pub const canSwapOperands = hir_effects_queries.canSwapOperands;
    pub const canMaterializeOperand = hir_effects_queries.canMaterializeOperand;
    pub const orderCompatible = hir_effects_queries.orderCompatible;
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

/// `build` plus host-module interface text (docs/host-bindings.md §3.4):
/// the `standard_library` map registers the module's members as host
/// bindings, which is how a white-box test gets more than one host
/// binding with a distinct effect declaration.
fn buildWithHostIface(
    entry: []const u8,
    texts: []const struct { []const u8, []const u8 },
    ifaces: []const struct { []const u8, []const u8 },
) !Fixture {
    var arena0 = std.heap.ArenaAllocator.init(testing.allocator);
    errdefer arena0.deinit();
    const arena = try arena0.allocator().create(std.heap.ArenaAllocator);
    arena.* = arena0;
    const alloc = arena.allocator();

    var sources = moduleinfo.Sources{};
    var source_map = std.StringHashMapUnmanaged([]const u8).empty;
    for (texts) |pair| try source_map.put(alloc, pair[0], pair[1]);
    sources.source = source_map;
    var iface_map = std.StringHashMapUnmanaged([]const u8).empty;
    for (ifaces) |pair| try iface_map.put(alloc, pair[0], pair[1]);
    sources.standard_library = iface_map;

    var builder = moduleinfo.Builder.init(alloc, sources);
    const graph = builder.build(entry) catch return error.Diagnostic;
    var ck = checker.Checker.init(alloc);
    _ = ck.check(graph) catch return error.Diagnostic;
    var bdiag: moduleinfo.Diag = undefined;
    const built = hir_build.buildProgramDiag(alloc, graph, &ck.annotation, &bdiag) catch return error.Diagnostic;
    return .{ .arena = arena, .built = built, .graph = graph };
}

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

fn funcId(f: *Fixture, name: []const u8) ?hir.FuncId {
    for (f.built.funcs.items, 0..) |rec, i| {
        if (std.mem.eql(u8, rec.name, name)) return @intCast(i);
    }
    return null;
}

fn bodyOf(p: *hir.Program, root: hir.ExprId) hir.ExprId {
    return p.region(p.regionsOf(root)[0]).root;
}

/// Declare every host binding of `f` as `forbidden` with `summary` — the
/// shape a white-box test that exercises *declared* host summaries needs
/// (docs/effects.md §13). Without the attestation a declaration is
/// `unknown` and resolves to `top`, which would make those tests pass
/// vacuously.
fn declareHosts(f: *Fixture, summary: effects.Summary) !effects.HostEffects {
    const entries = try f.arena.allocator().alloc(effects.HostEffects.Entry, f.built.hosts.items.len);
    for (f.built.hosts.items, 0..) |_, i| {
        entries[i] = .{ .host = @intCast(i), .summary = summary, .stilla_execution = .forbidden };
    }
    return .{ .entries = entries };
}

test "hir_effects: constant function bodies are pure and total" {
    var f = try build("app", &.{.{
        "app",
        \\fn double(x: int32) -> int32 { x * 2 }
    }});
    defer f.deinit();
    var an = try Analysis.init(f.arena.allocator(), f.built, .{ .graph = f.graph });
    try an.analyze();
    const fid = funcId(&f, "app.double").?;
    try testing.expect((try an.functionSummary(fid)).eql(effects.pure));
    try testing.expect((try an.validate(testing.allocator)) == null);
}

test "hir_effects: integer division is MayTrap, float division is Pure" {
    var f = try build("app", &.{.{
        "app",
        \\fn q(x: int32, y: int32) -> int32 { x / y }
        \\fn r(x: float32, y: float32) -> float32 { x / y }
    }});
    defer f.deinit();
    var an = try Analysis.init(f.arena.allocator(), f.built, .{ .graph = f.graph });
    try an.analyze();
    const idiv = try an.functionSummary(funcId(&f, "app.q").?);
    const fdiv = try an.functionSummary(funcId(&f, "app.r").?);
    try testing.expect(idiv.may_trap and !idiv.may_diverge);
    try testing.expect(fdiv.eql(effects.pure));
    try testing.expect((try an.validate(testing.allocator)) == null);
}

test "hir_effects: recursion gets the SCC least fixpoint, seeded may_diverge" {
    var f = try build("app", &.{.{
        "app",
        \\fn loop(n: int32) -> int32 { loop(n) }
        \\fn callit(n: int32) -> int32 { loop(n) }
    }});
    defer f.deinit();
    var an = try Analysis.init(f.arena.allocator(), f.built, .{ .graph = f.graph });
    try an.analyze();
    // docs/effects.md §8.2: a recursive SCC is seeded `Diverge`; the
    // least fixpoint is `(∅, false, true, false)`, *not* `Top`.
    try testing.expect((try an.functionSummary(funcId(&f, "app.loop").?)).eql(effects.may_diverge));
    // The divergence propagates to callers through the fixpoint.
    try testing.expect((try an.functionSummary(funcId(&f, "app.callit").?)).eql(effects.may_diverge));
    try testing.expect((try an.validate(testing.allocator)) == null);
}

test "hir_effects: never_returns from the signature and structurally" {
    var f = try build("app", &.{.{
        "app",
        \\const builtin = import("builtin");
        \\fn die() -> never { builtin.panic("x") }
        \\fn boom() -> void { builtin.panic("x") }
        \\fn ok() -> void { }
        \\fn val() -> int32 { 1 }
    }});
    defer f.deinit();
    var an = try Analysis.init(f.arena.allocator(), f.built, .{ .graph = f.graph });
    try an.analyze();
    // Declared `-> never` and the structurally-never `void` body are both
    // the must fact; a normal return path is not.
    try testing.expect(try an.neverReturns(funcId(&f, "app.die").?));
    try testing.expect(try an.neverReturns(funcId(&f, "app.boom").?));
    try testing.expect(!try an.neverReturns(funcId(&f, "app.ok").?));
    try testing.expect(!try an.neverReturns(funcId(&f, "app.val").?));
}

test "hir_effects: never_returns is the call-graph greatest fixpoint" {
    var f = try build("app", &.{.{
        "app",
        \\fn f() -> void { g() }
        \\fn g() -> void { f() }
        \\fn h(c: bool) -> int32 { if (c) { 1 } else { k() } }
        \\fn k() -> int32 { h(false) }
    }});
    defer f.deinit();
    var an = try Analysis.init(f.arena.allocator(), f.built, .{ .graph = f.graph });
    try an.analyze();
    // Coinductive: the `f ↔ g` cycle really never returns, so the
    // greatest fixpoint holds it (a least fixpoint seeded `false` would
    // drop both). One member of `h ↔ k` has a return path, so the whole
    // cycle falls out.
    try testing.expect(try an.neverReturns(funcId(&f, "app.f").?));
    try testing.expect(try an.neverReturns(funcId(&f, "app.g").?));
    try testing.expect(!try an.neverReturns(funcId(&f, "app.h").?));
    try testing.expect(!try an.neverReturns(funcId(&f, "app.k").?));
}

test "hir_effects: exprNever sees let-init, all-arm branches, and unresolved callees" {
    var f = try build("app", &.{.{
        "app",
        \\const builtin = import("builtin");
        \\fn boom() -> void { builtin.panic("x") }
        \\fn in_let() -> int32 { let x = boom(); 7 }
        \\fn both(c: bool) -> void { if (c) { boom() } else { boom() } }
        \\fn one(c: bool) -> void { if (c) { boom() } else { } }
    }});
    defer f.deinit();
    var an = try Analysis.init(f.arena.allocator(), f.built, .{ .graph = f.graph });
    try an.analyze();
    const pr = &f.built.program;
    try testing.expect(try an.exprNever(bodyOf(pr, f.built.funcs.items[funcId(&f, "app.in_let").?].root)));
    try testing.expect(try an.exprNever(bodyOf(pr, f.built.funcs.items[funcId(&f, "app.both").?].root)));
    // One arm returns normally: the branch may complete.
    try testing.expect(!try an.exprNever(bodyOf(pr, f.built.funcs.items[funcId(&f, "app.one").?].root)));
}

test "hir_effects: mutual recursion keeps real reads and still diverges" {
    var f = try build("app", &.{.{
        "app",
        \\const builtin = import("builtin");
        \\fn f(n: int32) -> int32 { if (n == 0) { 0 } else { g(n - 1) } }
        \\fn g(n: int32) -> int32 { builtin.print(builtin.str(n)); f(n) }
    }});
    defer f.deinit();
    const entries = try f.arena.allocator().alloc(effects.HostEffects.Entry, f.built.hosts.items.len);
    for (f.built.hosts.items, 0..) |_, i| {
        entries[i] = .{ .host = @intCast(i), .summary = try effects.summaryOf(f.arena.allocator(), &.{.{
            .resource = .{ .host = 7 },
            .mode = .write,
        }}), .stilla_execution = .forbidden };
    }
    var an = try Analysis.init(f.arena.allocator(), f.built, .{
        .graph = f.graph,
        .hosts = .{ .entries = entries },
    });
    try an.analyze();
    const fs = try an.functionSummary(funcId(&f, "app.f").?);
    const gs = try an.functionSummary(funcId(&f, "app.g").?);
    // Both members of the recursive SCC: may diverge, and the host write
    // is conservatively kept in the access row (§8.2 example).
    try testing.expect(fs.may_diverge and gs.may_diverge);
    try testing.expect(!effects.isObservableEffectFree(fs));
    try testing.expect(!effects.isObservableEffectFree(gs));
    try testing.expect(!fs.eql(effects.top));
    try testing.expect((try an.validate(testing.allocator)) == null);
}

test "hir_effects: pending facts fail queries closed; queries read annotations" {
    var f = try build("app", &.{.{
        "app",
        \\fn add(x: int32, y: int32) -> int32 { x + y }
    }});
    defer f.deinit();
    var an = try Analysis.init(f.arena.allocator(), f.built, .{ .graph = f.graph });
    const root = f.built.funcs.items[funcId(&f, "app.add").?].root;
    const body = bodyOf(&f.built.program, root);
    // Before analysis every annotation is pending: everything fails closed.
    try testing.expect(an.readySummary(body) == null);
    try testing.expect(!an.isTotal(body));
    try testing.expect(!(try an.isDiscardable(body)));
    try testing.expect(!(try an.isDuplicable(body)));
    try testing.expect(!(try an.isSegSafe(body)));
    try testing.expect(!(try an.isIntrinsicallySpeculatable(body)));
    try testing.expect(!(try an.canFloatAsTree(body)));

    try an.analyze();
    try testing.expect(an.readySummary(body) != null);
    try testing.expect(an.isTotal(body));
    try testing.expect(try an.isDiscardable(body));
    try testing.expect(try an.isDuplicable(body));
    try testing.expect(try an.isSegSafe(body));
    try testing.expect(try an.canFloatAsTree(body));
    // Semantic safety is separate from encoding support (M2a registers
    // the island set, so this `add.i32` body is both safe and encodable).
    try testing.expect(an.hasSegEncoding(f.built.program.node(body).op));
    try testing.expect(try an.isSegAdmissible(body));
}

test "hir_effects: stored annotations are sound over-approximations; tampering is rejected" {
    var f = try build("app", &.{.{
        "app",
        \\fn q(x: int32, y: int32) -> int32 { x / y }
    }});
    defer f.deinit();
    var an = try Analysis.init(f.arena.allocator(), f.built, .{ .graph = f.graph });
    try an.analyze();
    try testing.expect((try an.validate(testing.allocator)) == null);

    const root = f.built.funcs.items[funcId(&f, "app.q").?].root;
    const body = bodyOf(&f.built.program, root);
    // Widen a stored summary to Top: still a sound over-approximation.
    const top_id = try f.built.program.effect_interner.summaryId(effects.top);
    try f.built.program.setEffect(body, .{ .ready = top_id });
    try testing.expect((try an.validate(testing.allocator)) == null);
    // Narrow a stored summary to Pure: unsound, must be rejected.
    const pure_id = f.built.program.effect_interner.pureId();
    try f.built.program.setEffect(body, .{ .ready = pure_id });
    const msg = try an.validate(testing.allocator);
    try testing.expect(msg != null);
    testing.allocator.free(msg.?);
    // A pending annotation is rejected too.
    try f.built.program.setEffect(body, .pending);
    const msg2 = try an.validate(testing.allocator);
    try testing.expect(msg2 != null);
    testing.allocator.free(msg2.?);
}

test "hir_effects: SCC-fixpoint summaries are re-derived; a call annotation cannot under-approximate them" {
    // M2b: the validator re-runs the SCC least fixpoint (docs/effects.md
    // §8.2/§8.3), so a call node annotated below the callee's derived
    // summary is rejected.
    var f = try build("app", &.{.{
        "app",
        \\const later: int32 = 3;
        \\fn leak() -> int32 { later }
        \\fn caller() -> int32 { leak() }
    }});
    defer f.deinit();
    var an = try Analysis.init(f.arena.allocator(), f.built, .{ .graph = f.graph });
    try an.analyze();
    try testing.expect((try an.validate(testing.allocator)) == null);
    const caller = funcId(&f, "app.caller").?;
    const body = bodyOf(&f.built.program, f.built.funcs.items[caller].root);
    // Widen to Top: sound. Narrow to Pure: the callee reads a module
    // constant, so the derived call summary does not fit in Pure.
    const top_id2 = try f.built.program.effect_interner.summaryId(effects.top);
    try f.built.program.setEffect(body, .{ .ready = top_id2 });
    try testing.expect((try an.validate(testing.allocator)) == null);
    try f.built.program.setEffect(body, .{ .ready = f.built.program.effect_interner.pureId() });
    const msg = try an.validate(testing.allocator);
    try testing.expect(msg != null);
    testing.allocator.free(msg.?);
}

test "hir_effects: drop_effect walks the field/hook chain (teardown closed over containers)" {
    // docs/effects.md §7.2/§11.1: the teardown read set is the whole
    // destruction chain — the struct's own hook plus every Unique field's
    // hook — not just the type-direct hook. `Pair` has no hook of its
    // own; both `File` fields do.
    var f = try build("app", &.{.{
        "app",
        \\const base: int32 = 2;
        \\struct File { fd: int32; drop(f) { let _ = base; } }
        \\struct Pair { a: File; b: File; }
        \\const g: Pair = Pair { a: File{fd:1}, b: File{fd:2} };
    }});
    defer f.deinit();
    var an = try Analysis.init(f.arena.allocator(), f.built, .{ .graph = f.graph });
    try an.analyze();
    // The chain is non-trivial and free of any violation (base precedes g).
    const pair_ty = findStructTy(&f, "Pair") orelse return error.TestUnexpectedResult;
    const de = try an.dropEffectOf(pair_ty);
    try testing.expect(!effects.isPure(de));
    var saw_const_read = false;
    for (de.accesses.accesses) |a| {
        if (a.mode == .read and a.resource == .module_const) saw_const_read = true;
    }
    try testing.expect(saw_const_read);
    try testing.expect((try an.checkModuleDependencies(testing.allocator)) == null);
}

test "hir_effects: a cross-layer hook/fn/type cycle resolves precisely" {
    // `f` destroys a `Token` (cleanup token edge `f → drop_type(Token)`),
    // whose hook calls `f` (`drop_type → function`). Before the unified
    // graph the missing cleanup-token edge left `f` outside the hook's
    // SCC, so it could be solved first and fall back to `Top`; now all
    // three nodes share one SCC and reach the least fixpoint.
    var f = try build("app", &.{.{
        "app",
        \\struct Token {
        \\    id: int32;
        \\    drop(t) { f(t.id); }
        \\}
        \\fn f(id: int32) -> int32 {
        \\    let t = Token { id: id };
        \\    0
        \\}
    }});
    defer f.deinit();
    var an = try Analysis.init(f.arena.allocator(), f.built, .{ .graph = f.graph });
    try an.analyze();
    const fsum = try an.functionSummary(funcId(&f, "app.f").?);
    // The cycle is a genuine function recursion, so the SCC is seeded
    // `may_diverge`; crucially the result is the precise `Diverge`, not
    // the full `Top` the cross-layer fallback used to publish.
    try testing.expect(!fsum.eql(effects.top));
    try testing.expect(fsum.eql(effects.may_diverge));
    try testing.expect((try an.validate(testing.allocator)) == null);
}

test "hir_effects: a purely recursive drop type does not acquire may_diverge" {
    // `T` reaches itself through `box[T]`, so its two drop nodes form a
    // recursive SCC. No function participates, so the SCC is seeded
    // `pure` by kind: a recursive *type* must not be conflated with a
    // recursive *function* (docs/effects.md §11.1 按 kind 播种).
    var f = try build("app", &.{.{
        "app",
        \\struct T {
        \\    id: int32;
        \\    next: box[T];
        \\    drop(t) { let x = t.id; }
        \\}
        \\fn consume(move t: T) -> int32 { 0 }
    }});
    defer f.deinit();
    var an = try Analysis.init(f.arena.allocator(), f.built, .{ .graph = f.graph });
    try an.analyze();
    const t_ty = findStructTy(&f, "T") orelse return error.TestUnexpectedResult;
    const d = try an.dropEffectOf(t_ty);
    try testing.expect(!d.may_diverge);
    try testing.expect(effects.isPure(d));
    // The type-keyed accessor records the same interned summary.
    const key = try f.built.program.intern(t_ty);
    try testing.expect((try an.dropSummary(key)).eql(d));
    try testing.expect((try an.validate(testing.allocator)) == null);
}

fn findStructTy(f: *Fixture, name: []const u8) ?meta.Type {
    for (f.built.types, 0..) |d, i| {
        const dname = switch (d) {
            .struct_ => |s| s.name,
            .union_ => |u| u.name,
            .opaque_ => |o| o.name,
            .unknown => continue,
        };
        if (std.mem.eql(u8, dname, name)) return .{ .named = .{ .id = @intCast(i), .args = &.{} } };
    }
    return null;
}

test "hir_effects: module constants read ModuleConst" {
    var f = try build("app", &.{.{
        "app",
        \\const base: int32 = 3;
        \\fn get() -> int32 { base }
    }});
    defer f.deinit();
    var an = try Analysis.init(f.arena.allocator(), f.built, .{ .graph = f.graph });
    try an.analyze();
    const get = try an.functionSummary(funcId(&f, "app.get").?);
    try testing.expect(!get.accesses.isEmpty());
    switch (get.accesses.accesses[0].resource) {
        .module_const => {},
        else => return error.TestUnexpectedResult,
    }
    try testing.expectEqual(effects.EffectMode.read, get.accesses.accesses[0].mode);
    try testing.expect((try an.validate(testing.allocator)) == null);
}

test "hir_effects: undeclared host metadata is Top, declared metadata refines it" {
    var f = try build("app", &.{.{
        "app",
        \\const builtin = import("builtin");
        \\fn shout(x: int32) -> void { builtin.print(builtin.str(x)) }
    }});
    defer f.deinit();
    const shout = funcId(&f, "app.shout").?;

    var an = try Analysis.init(f.arena.allocator(), f.built, .{ .graph = f.graph });
    try an.analyze();
    // Undeclared host metadata is the *full* Top (docs/effects.md §13):
    // the compiler cannot prove the binding cannot execute Stilla code, so
    // it may reach any module constant.
    const undeclared = try an.functionSummary(shout);
    try testing.expect(undeclared.eql(effects.top));
    try testing.expect(undeclared.accesses.wildcard(.read));
    try testing.expect((try an.validate(testing.allocator)) == null);

    // Declare every host binding pure *and* `forbidden`: the host call
    // (and the intrinsic wrapper behind `builtin.str`) becomes pure. The
    // attestation is what makes the declared summary apply at all.
    const hosts = try declareHosts(&f, effects.pure);
    var an2 = try Analysis.init(f.arena.allocator(), f.built, .{
        .graph = f.graph,
        .hosts = hosts,
    });
    try an2.analyze();
    try testing.expect((try an2.functionSummary(shout)).eql(effects.pure));
    try testing.expect((try an2.validate(testing.allocator)) == null);
}

test "hir_effects: operand uses resolve from the op contract" {
    var f = try build("app", &.{.{
        "app",
        \\fn consume(x: int32) -> int32 { move x }
        \\fn lend(borrow x: int32) -> int32 { x }
    }});
    defer f.deinit();
    var an = try Analysis.init(f.arena.allocator(), f.built, .{ .graph = f.graph });
    try an.analyze();
    var seen_move = false;
    for (f.built.program.exprs.items, 0..) |e, i| {
        const name = hir.registry.get(e.op).name;
        const id: hir.ExprId = @intCast(i);
        if (std.mem.eql(u8, name, "move")) {
            try testing.expectEqual(effects.OperandUse.consume, try an.operandUseOf(id, 0));
            seen_move = true;
        } else if (std.mem.eql(u8, name, "borrow")) {
            try testing.expectEqual(effects.OperandUse.borrow, try an.operandUseOf(id, 0));
        }
    }
    try testing.expect(seen_move);
}

test "hir_effects: equal summaries never authorize a swap by themselves" {
    var f = try build("app", &.{.{
        "app",
        \\const base: int32 = 3;
        \\fn twice() -> int32 { base + base }
    }});
    defer f.deinit();
    var an = try Analysis.init(f.arena.allocator(), f.built, .{ .graph = f.graph });
    try an.analyze();
    for (f.built.program.exprs.items, 0..) |e, i| {
        if (!std.mem.eql(u8, hir.registry.get(e.op).name, "add.i32")) continue;
        const id: hir.ExprId = @intCast(i);
        const ops = f.built.program.operands(id);
        if (ops.len != 2) continue;
        const sa = an.readySummary(ops[0]) orelse continue;
        const sb = an.readySummary(ops[1]) orelse continue;
        if (!sa.eql(sb) or sa.accesses.accesses.len == 0) continue;
        // Identical summaries: the swap is still gated by the
        // resource/trap-compatibility input. Undeclared read domains
        // conflict.
        try testing.expect(!(try an.canSwapOperands(id, 0, 1)));
        // Declaring the read domain stable makes the same swap legal.
        var stable = [_]effects.EffectResource{sa.accesses.accesses[0].resource};
        var an2 = try Analysis.init(f.arena.allocator(), f.built, .{
            .graph = f.graph,
            .resources = .{ .stable = &stable },
        });
        try an2.analyze();
        try testing.expect(try an2.canSwapOperands(id, 0, 1));
        // Non-adjacent / wrong-policy parents are refused.
        try testing.expect(!(try an2.canSwapOperands(id, 0, 3)));
        return;
    }
    return error.TestUnexpectedResult;
}

test "hir_effects: host calls with an effectful declared summary are not discardable" {
    var f = try build("app", &.{.{
        "app",
        \\const builtin = import("builtin");
        \\fn shout(x: int32) -> void { builtin.print(builtin.str(x)) }
    }});
    defer f.deinit();
    const write_effects = try effects.summaryOf(f.arena.allocator(), &.{.{
        .resource = .{ .host = 1 },
        .mode = .write,
    }});
    const entries = try f.arena.allocator().alloc(effects.HostEffects.Entry, f.built.hosts.items.len);
    for (f.built.hosts.items, 0..) |_, i| {
        entries[i] = .{ .host = @intCast(i), .summary = write_effects, .stilla_execution = .forbidden };
    }
    var an = try Analysis.init(f.arena.allocator(), f.built, .{
        .graph = f.graph,
        .hosts = .{ .entries = entries },
    });
    try an.analyze();
    // Find the print call node and check it is neither discardable nor
    // seg-safe.
    var found = false;
    for (f.built.program.exprs.items, 0..) |e, i| {
        if (!std.mem.eql(u8, hir.registry.get(e.op).name, "call")) continue;
        const id: hir.ExprId = @intCast(i);
        const s = an.readySummary(id) orelse continue;
        if (!effects.isObservableEffectFree(s)) {
            try testing.expect(!(try an.isDiscardable(id)));
            try testing.expect(!(try an.isSegSafe(id)));
            found = true;
        }
    }
    try testing.expect(found);
}

test "hir_effects: a trapping division is never discardable" {
    var f = try build("app", &.{.{
        "app",
        \\fn f(y: int32) -> int32 {
        \\    let x: int32 = 10 / y;
        \\    0
        \\}
    }});
    defer f.deinit();
    var an = try Analysis.init(f.arena.allocator(), f.built, .{ .graph = f.graph });
    try an.analyze();
    var found = false;
    for (f.built.program.exprs.items, 0..) |e, i| {
        if (!std.mem.eql(u8, hir.registry.get(e.op).name, "div.i32")) continue;
        const id: hir.ExprId = @intCast(i);
        try testing.expect(!(try an.isDiscardable(id)));
        try testing.expect(!(try an.isSegSafe(id)));
        try testing.expect(!(try an.isDuplicable(id)));
        found = true;
    }
    try testing.expect(found);
    try testing.expect((try an.validate(testing.allocator)) == null);
}

test "hir_effects: a Copy result with a scoped Unique destructor is resolved precisely" {
    var f = try build("app", &.{.{
        "app",
        \\struct Token {
        \\    id: int32;
        \\    drop(t) {
        \\        let x = t.id;
        \\    }
        \\}
        \\fn inner(id: int32) -> int32 {
        \\    let t = Token { id: id };
        \\    0
        \\}
        \\fn outer(id: int32) -> int32 { inner(id) }
    }});
    defer f.deinit();
    var an = try Analysis.init(f.arena.allocator(), f.built, .{ .graph = f.graph });
    try an.analyze();
    // Before the unified dependency graph the cleanup-token edge
    // `inner → Token` was missing, so `inner` could be solved before the
    // hook's SCC and fall back to `Top`. The extra edge closes the
    // cross-layer cycle and the reading destructor gives a precise,
    // purely-reading summary.
    const inner = try an.functionSummary(funcId(&f, "app.inner").?);
    try testing.expect(!inner.eql(effects.top));
    try testing.expect(effects.isTotal(inner));
    try testing.expect(effects.isPure(inner));
    // A call to it is therefore discardable / floatable / SEG-safe: the
    // Copy result carries no observable destructor.
    var found = false;
    for (f.built.program.exprs.items, 0..) |e, i| {
        if (!std.mem.eql(u8, hir.registry.get(e.op).name, "call")) continue;
        const id: hir.ExprId = @intCast(i);
        try testing.expect(try an.isDiscardable(id));
        try testing.expect(try an.canFloatAsTree(id));
        try testing.expect(try an.isSegSafe(id));
        try testing.expect(try an.isIntrinsicallySpeculatable(id));
        found = true;
    }
    try testing.expect(found);
    try testing.expect((try an.validate(testing.allocator)) == null);
}

test "hir_effects: Q blocks duplication but not discard" {
    var f = try build("app", &.{.{
        "app",
        \\const builtin = import("builtin");
        \\fn label(x: int32) -> str { builtin.str(x) }
    }});
    defer f.deinit();
    const q = Summary{
        .accesses = (try effects.summaryOf(f.arena.allocator(), &.{.{
            .resource = .{ .host = 1 },
            .mode = .read,
        }})).accesses,
        .may_trap = false,
        .may_diverge = false,
        .nondeterministic = true,
    };
    const entries = try f.arena.allocator().alloc(effects.HostEffects.Entry, f.built.hosts.items.len);
    for (f.built.hosts.items, 0..) |_, i| {
        entries[i] = .{ .host = @intCast(i), .summary = q, .stilla_execution = .forbidden };
    }
    var an = try Analysis.init(f.arena.allocator(), f.built, .{
        .graph = f.graph,
        .hosts = .{ .entries = entries },
    });
    try an.analyze();
    var found = false;
    for (f.built.program.exprs.items, 0..) |e, i| {
        if (!std.mem.eql(u8, hir.registry.get(e.op).name, "call")) continue;
        const id: hir.ExprId = @intCast(i);
        const s = an.readySummary(id) orelse continue;
        if (!s.nondeterministic) continue;
        // `let x = clock.now() in 0` is legal: Q does not make a total,
        // read-only evaluation observable.
        try testing.expect(try an.isDiscardable(id));
        // But the result is unstable: never duplicate or CSE it.
        try testing.expect(!(try an.isDuplicable(id)));
        found = true;
    }
    try testing.expect(found);
}

test "hir_effects: a conditional panic keeps MayTrap through the call summary" {
    var f = try build("app", &.{.{
        "app",
        \\const builtin = import("builtin");
        \\fn boom(c: bool) -> int32 { if (c) { builtin.panic("boom") } else { 0 } }
        \\fn callit(c: bool) -> int32 { boom(c) }
    }});
    defer f.deinit();
    const entries = try f.arena.allocator().alloc(effects.HostEffects.Entry, f.built.hosts.items.len);
    for (f.built.hosts.items, 0..) |_, i| {
        entries[i] = .{ .host = @intCast(i), .summary = effects.may_trap, .stilla_execution = .forbidden };
    }
    var an = try Analysis.init(f.arena.allocator(), f.built, .{
        .graph = f.graph,
        .hosts = .{ .entries = entries },
    });
    try an.analyze();
    const boom = try an.functionSummary(funcId(&f, "app.boom").?);
    try testing.expect(boom.may_trap);
    const callit = try an.functionSummary(funcId(&f, "app.callit").?);
    try testing.expect(callit.may_trap);
    for (f.built.program.exprs.items, 0..) |e, i| {
        if (!std.mem.eql(u8, hir.registry.get(e.op).name, "call")) continue;
        const id: hir.ExprId = @intCast(i);
        const s = an.readySummary(id) orelse continue;
        if (s.may_trap) {
            try testing.expect(!(try an.isDiscardable(id)));
            return;
        }
    }
    return error.TestUnexpectedResult;
}

test "hir_effects: a call summary includes the callable's effect_bound" {
    // The callable here is reached through an ordinary callee whose own
    // body carries a Write: the call node must inherit it. (A separate
    // test covers a *non-`fn_ref`* callee expression being sequenced.)
    var f = try build("app", &.{.{
        "app",
        \\const builtin = import("builtin");
        \\fn pick(x: int32) -> str { builtin.str(x) }
        \\fn use(x: int32) -> str { pick(x) }
    }});
    defer f.deinit();
    const write = try effects.summaryOf(f.arena.allocator(), &.{.{
        .resource = .{ .host = 2 },
        .mode = .write,
    }});
    const entries = try f.arena.allocator().alloc(effects.HostEffects.Entry, f.built.hosts.items.len);
    for (f.built.hosts.items, 0..) |_, i| {
        entries[i] = .{ .host = @intCast(i), .summary = write, .stilla_execution = .forbidden };
    }
    var an = try Analysis.init(f.arena.allocator(), f.built, .{
        .graph = f.graph,
        .hosts = .{ .entries = entries },
    });
    try an.analyze();
    // The call node must carry the callee's Write effect (evaluating the
    // callee is sequenced into the call, never dropped).
    var found = false;
    for (f.built.program.exprs.items, 0..) |e, i| {
        if (!std.mem.eql(u8, hir.registry.get(e.op).name, "call")) continue;
        const id: hir.ExprId = @intCast(i);
        const s = an.readySummary(id) orelse continue;
        if (!effects.isObservableEffectFree(s)) found = true;
    }
    try testing.expect(found);
    try testing.expect((try an.validate(testing.allocator)) == null);
}

test "hir_effects: a value-position module chain leaf is conservatively Top" {
    // `lib.math.sqrt` in value position is lowered as `module_ref` +
    // `load_member`, and `module_ref` can run module initialization — an
    // unmodelled effect, so the leaf must not claim `fn_ref`'s Pure.
    var f = try build("app", &.{
        .{ "math", "fn sqrt(x: int32) -> int32 { x }" },
        .{ "lib", "const math = import(\"math\");" },
        .{
            "app",
            \\const lib = import("lib");
            \\fn get() -> fn(int32) -> int32 { lib.math.sqrt }
        },
    });
    defer f.deinit();
    var an = try Analysis.init(f.arena.allocator(), f.built, .{ .graph = f.graph });
    try an.analyze();
    var found = false;
    for (f.built.program.exprs.items, 0..) |e, i| {
        if (e.access_hops.len == 0) continue;
        const id: hir.ExprId = @intCast(i);
        try testing.expect((an.readySummary(id) orelse effects.pure).eql(effects.top));
        found = true;
    }
    try testing.expect(found);
    try testing.expect((try an.validate(testing.allocator)) == null);
}

test "hir_effects: struct field reads stay total and pure" {
    // `field_get` lowers to `read_field` (nominal struct) — total and
    // effect-free. A precision check: struct-heavy code must not degrade
    // to `Top`.
    var f = try build("app", &.{.{
        "app",
        \\struct P {
        \\    x: int32;
        \\    y: int32;
        \\}
        \\fn getx(borrow p: P) -> int32 { p.x }
        \\fn gety(p: P) -> int32 { p.y }
    }});
    defer f.deinit();
    var an = try Analysis.init(f.arena.allocator(), f.built, .{ .graph = f.graph });
    try an.analyze();
    try testing.expect((try an.functionSummary(funcId(&f, "app.getx").?)).eql(effects.pure));
    try testing.expect((try an.functionSummary(funcId(&f, "app.gety").?)).eql(effects.pure));
    try testing.expect((try an.validate(testing.allocator)) == null);
}

test "hir_effects: list patterns are MayTrap at the let node, tuple patterns are not" {
    // A list pattern's element access lowers to a bounds-checked
    // `read_index`/`split_list` (cfg may_trap); it is not an HIR node, so
    // the `let_` transfer must sequence it. Tuple destructuring lowers to
    // a total `read_tuple` and must stay pure. Assert on the `let` node's
    // *eval* summary (its operand and body are pure locals), which
    // isolates the pattern transfer from the cleanup gate that would
    // otherwise make any list-touching expression `Top`.
    var f = try build("app", &.{.{
        "app",
        \\fn head(borrow xs: list[int32]) -> int32 {
        \\    let [h, ..rest] = xs;
        \\    h
        \\}
        \\fn second(borrow t: tuple[int32, int32]) -> int32 {
        \\    let (a, b) = t;
        \\    b
        \\}
    }});
    defer f.deinit();
    var an = try Analysis.init(f.arena.allocator(), f.built, .{ .graph = f.graph });
    try an.analyze();
    var list_let = false;
    var tuple_let = false;
    for (f.built.program.exprs.items, 0..) |e, i| {
        if (!std.mem.eql(u8, hir.registry.get(e.op).name, "let")) continue;
        const id: hir.ExprId = @intCast(i);
        const rid = f.built.program.regionsOf(id)[0];
        const pat = f.built.program.region(rid).pattern orelse continue;
        const s = an.readySummary(id) orelse continue;
        switch (f.built.program.pattern(pat)) {
            .list => {
                try testing.expect(s.may_trap);
                list_let = true;
            },
            .tuple => {
                try testing.expect(!s.may_trap);
                tuple_let = true;
            },
            else => {},
        }
    }
    try testing.expect(list_let and tuple_let);
    try testing.expect((try an.validate(testing.allocator)) == null);
}

test "hir_effects: a nested move makes an otherwise pure expression non-discardable" {
    // `move x` has `effects == {}` but a `Consume` operand use; the
    // ownership gate must recurse into operands, or a Copy-typed `move`
    // nested under pure arithmetic escapes every query.
    var f = try build("app", &.{.{
        "app",
        \\fn sink(x: int32) -> int32 { (move x) + 1 }
    }});
    defer f.deinit();
    var an = try Analysis.init(f.arena.allocator(), f.built, .{ .graph = f.graph });
    try an.analyze();
    var checked = false;
    for (f.built.program.exprs.items, 0..) |e, i| {
        if (!std.mem.eql(u8, hir.registry.get(e.op).name, "move")) continue;
        const id: hir.ExprId = @intCast(i);
        try testing.expect(!(try an.ownershipGate(id)));
        try testing.expect(!(try an.isDiscardable(id)));
        try testing.expect(!(try an.isDuplicable(id)));
        try testing.expect(!(try an.isSegSafe(id)));
        try testing.expect(!(try an.isIntrinsicallySpeculatable(id)));
        checked = true;
    }
    try testing.expect(checked);
    // The enclosing arithmetic must also fail every query.
    for (f.built.program.exprs.items, 0..) |e, i| {
        if (!std.mem.eql(u8, hir.registry.get(e.op).name, "add.i32")) continue;
        const id: hir.ExprId = @intCast(i);
        try testing.expect(!(try an.ownershipGate(id)));
        try testing.expect(!(try an.isDiscardable(id)));
        try testing.expect(!(try an.isDuplicable(id)));
        try testing.expect(!(try an.canFloatAsTree(id)));
        try testing.expect(!(try an.isSegSafe(id)));
        try testing.expect(!(try an.isIntrinsicallySpeculatable(id)));
        try testing.expect(!(try an.canSwapOperands(id, 0, 1)));
    }
    try testing.expect((try an.validate(testing.allocator)) == null);
}

test "hir_effects: a consumed parent slot blocks a swap even with pure operands" {
    // The argument subtrees are pure Copy locals, but the `move`
    // parameter makes the parent `call` consume each argument slot:
    // `canSwapOperands` must read the *parent's* operand use.
    var f = try build("app", &.{.{
        "app",
        \\fn take(move x: int32, y: int32) -> int32 { x + y }
        \\fn outer(a: int32, b: int32) -> int32 { take(a, b) }
    }});
    defer f.deinit();
    var an = try Analysis.init(f.arena.allocator(), f.built, .{ .graph = f.graph });
    try an.analyze();
    var checked = false;
    for (f.built.program.exprs.items, 0..) |e, i| {
        if (!std.mem.eql(u8, hir.registry.get(e.op).name, "call")) continue;
        const id: hir.ExprId = @intCast(i);
        const ops = f.built.program.operands(id);
        if (ops.len != 3) continue; // callee + two args
        try testing.expectEqual(effects.OperandUse.consume, try an.operandUseOf(id, 1));
        try testing.expect(!(try an.canSwapOperands(id, 1, 2)));
        checked = true;
    }
    try testing.expect(checked);
    try testing.expect((try an.validate(testing.allocator)) == null);
}

test "hir_effects: argument effects are sequenced into a pure callable's call" {
    // The callable's `effect_bound` is Pure, so the only way the call
    // summary becomes observable is by sequencing the *argument*
    // expression (a host call) before it. (The callee-expression term of
    // `effect_transfer` cannot be isolated the same way: for every
    // non-`fn_ref`/non-λ callee `effect_bound` is already `Top`, which
    // dominates the summary — see the field-by-field transfer in
    // `compute`.)
    var f = try build("app", &.{.{
        "app",
        \\const builtin = import("builtin");
        \\fn count(s: str) -> int32 { 0 }
        \\fn outer(x: int32) -> int32 { count(builtin.str(x)) }
    }});
    defer f.deinit();
    const entries = try f.arena.allocator().alloc(effects.HostEffects.Entry, f.built.hosts.items.len);
    const write = try effects.summaryOf(f.arena.allocator(), &.{.{
        .resource = .{ .host = 9 },
        .mode = .write,
    }});
    for (f.built.hosts.items, 0..) |_, i| {
        entries[i] = .{ .host = @intCast(i), .summary = write, .stilla_execution = .forbidden };
    }
    var an = try Analysis.init(f.arena.allocator(), f.built, .{
        .graph = f.graph,
        .hosts = .{ .entries = entries },
    });
    try an.analyze();
    try testing.expect((try an.functionSummary(funcId(&f, "app.count").?)).eql(effects.pure));
    var found = false;
    for (f.built.program.exprs.items, 0..) |e, i| {
        if (!std.mem.eql(u8, hir.registry.get(e.op).name, "call")) continue;
        const id: hir.ExprId = @intCast(i);
        const ops = f.built.program.operands(id);
        if (ops.len < 2) continue;
        if (!std.mem.eql(u8, hir.registry.get(f.built.program.node(ops[0]).op).name, "fn_ref")) continue;
        const s = an.readySummary(id) orelse continue;
        if (!effects.isObservableEffectFree(s)) found = true;
    }
    try testing.expect(found);
    try testing.expect((try an.validate(testing.allocator)) == null);
}

test "hir_effects: validation re-derives summaries (stale *caller* facts are rejected)" {
    var f = try build("app", &.{.{
        "app",
        \\fn callee() -> int32 { 7 }
        \\fn caller() -> int32 { callee() }
    }});
    defer f.deinit();
    var an = try Analysis.init(f.arena.allocator(), f.built, .{ .graph = f.graph });
    try an.analyze();
    try testing.expect((try an.validate(testing.allocator)) == null);
    // Mutate the callee body to a trapping op *after* analysis, then
    // refresh only the callee's own stored annotations. The caller's
    // stored (Pure) facts are now stale; a fresh derivation (memo cleared
    // before the summaries are recomputed) must reject the caller.
    const callee_root = f.built.funcs.items[funcId(&f, "app.callee").?].root;
    const callee_body = bodyOf(&f.built.program, callee_root);
    f.built.program.exprs.items[callee_body].op = hir.opId("panic").?;
    @memset(an.memo, null);
    try an.annotateTree(callee_root);
    const msg = try an.validate(testing.allocator);
    try testing.expect(msg != null);
    defer testing.allocator.free(msg.?);
    // The violation must be attributed to the caller, not the (now
    // consistent) callee.
    try testing.expect(std.mem.indexOf(u8, msg.?, "app.caller") != null);
}

/// Find the `call` node whose callee is a host binding (the white-box
/// callback tests have exactly one).
fn findHostCall(f: *Fixture) ?hir.ExprId {
    const p = &f.built.program;
    for (p.exprs.items, 0..) |e, i| {
        if (e.op != call_op) continue;
        const ops = p.operands(@intCast(i));
        if (ops.len == 0) continue;
        const callee = p.node(ops[0]);
        if (callee.op != fn_ref_op or callee.payload != .func) continue;
        switch (callee.payload.func) {
            .host => return @intCast(i),
            .func => {},
        }
    }
    return null;
}

/// Declare one host binding `may_execute` with `summary` + `callbacks`;
/// every other binding is `forbidden` + pure, so only the target's
/// contract can shape the result.
fn declareCallbackHost(f: *Fixture, key: []const u8, summary: effects.Summary, callbacks: ?[]const u32) !effects.HostEffects {
    const a = f.arena.allocator();
    const entries = try a.alloc(effects.HostEffects.Entry, f.built.hosts.items.len);
    for (f.built.hosts.items, 0..) |hb, i| {
        const target = std.mem.eql(u8, hb.key, key);
        entries[i] = .{
            .host = @intCast(i),
            .summary = if (target) summary else effects.pure,
            .stilla_execution = if (target) .may_execute else .forbidden,
            .callbacks = if (target) callbacks else null,
        };
    }
    return .{ .entries = entries };
}

test "hir_effects: a host callback contract bounds the call by the passed target" {
    var f = try build("app", &.{
        .{ "hostmod", "fn apply(f: fn(int32) -> int32, x: int32) -> int32;" },
        .{
            "app",
            \\const hostmod = import("hostmod");
            \\const base: int32 = 7;
            \\fn readbase(x: int32) -> int32 { x + base }
            \\fn main() -> int32 { hostmod.apply(readbase, 3) }
        },
    });
    defer f.deinit();
    const call = findHostCall(&f).?;
    const pos0 = [_]u32{0};

    // Without the contract a `may_execute` host is Top, even though the
    // callable argument is statically a direct `fn_ref`.
    const bare = try declareCallbackHost(&f, "hostmod.apply", effects.pure, null);
    var an_bare = try Analysis.init(f.arena.allocator(), f.built, .{ .graph = f.graph, .hosts = bare });
    try an_bare.analyze();
    try testing.expect((try an_bare.effectOf(call)).eql(effects.top));
    try testing.expect((try an_bare.validate(testing.allocator)) == null);

    // With the exhaustive synchronous contract the call is exactly
    // `own ⊔ effect_bound(readbase)` = readbase's module-const read.
    const hosts = try declareCallbackHost(&f, "hostmod.apply", effects.pure, &pos0);
    var an = try Analysis.init(f.arena.allocator(), f.built, .{ .graph = f.graph, .hosts = hosts });
    try an.analyze();
    const sum = try an.effectOf(call);
    try testing.expect(sum.eql(try an.functionSummary(funcId(&f, "app.readbase").?)));
    try testing.expectEqual(@as(usize, 1), sum.accesses.accesses.len);
    switch (sum.accesses.accesses[0].resource) {
        .module_const => {},
        else => return error.TestUnexpectedResult,
    }
    try testing.expectEqual(effects.EffectMode.read, sum.accesses.accesses[0].mode);
    try testing.expect((try an.validate(testing.allocator)) == null);

    // An `unknown` execution attestation does not use the contract: the
    // same call with the same provable target is Top.
    const a1 = f.arena.allocator();
    const unknown_entries = try a1.alloc(effects.HostEffects.Entry, f.built.hosts.items.len);
    for (f.built.hosts.items, 0..) |hb, i| {
        const target = std.mem.eql(u8, hb.key, "hostmod.apply");
        unknown_entries[i] = .{
            .host = @intCast(i),
            .summary = effects.pure,
            .stilla_execution = .unknown,
            .callbacks = if (target) &pos0 else null,
        };
    }
    var an_unknown = try Analysis.init(a1, f.built, .{ .graph = f.graph, .hosts = .{ .entries = unknown_entries } });
    try an_unknown.analyze();
    try testing.expect((try an_unknown.effectOf(call)).eql(effects.top));
}

test "hir_effects: an inline-lambda callback argument bounds the host call" {
    var f = try build("app", &.{
        .{ "hostmod", "fn apply(f: fn(int32) -> int32, x: int32) -> int32;" },
        .{
            "app",
            \\const hostmod = import("hostmod");
            \\const base: int32 = 7;
            \\fn main() -> int32 { hostmod.apply(fn(x: int32) -> int32 { x + base }, 3) }
        },
    });
    defer f.deinit();
    const call = findHostCall(&f).?;
    const pos0 = [_]u32{0};
    const hosts = try declareCallbackHost(&f, "hostmod.apply", effects.pure, &pos0);
    var an = try Analysis.init(f.arena.allocator(), f.built, .{ .graph = f.graph, .hosts = hosts });
    try an.analyze();
    // An inline λ is a provable singleton target too, so the call is
    // bounded by its body's effects — the module-const read — not Top.
    const sum = try an.effectOf(call);
    try testing.expect(!sum.eql(effects.top));
    try testing.expectEqual(@as(usize, 1), sum.accesses.accesses.len);
    switch (sum.accesses.accesses[0].resource) {
        .module_const => {},
        else => return error.TestUnexpectedResult,
    }
    try testing.expect((try an.validate(testing.allocator)) == null);
}

test "hir_effects: a host callback contract honours a let-bound target and refuses invalid positions" {
    var f = try build("app", &.{
        .{ "hostmod", "fn apply(f: fn(int32) -> int32, x: int32) -> int32;" },
        .{ "impl", "fn inc(x: int32) -> int32 { x + 1 }" },
        .{
            "app",
            \\const hostmod = import("hostmod");
            \\const impl = import("impl");
            \\fn main() -> int32 {
            \\    let g = impl.inc;
            \\    hostmod.apply(g, 3)
            \\}
        },
    });
    defer f.deinit();
    const call = findHostCall(&f).?;
    const pos0 = [_]u32{0};

    // A `let`-bound callable resolves to a provable finite target set by
    // the §9.2 local propagation, so the contract applies: the call is
    // `own ⊔ summary(impl.inc)` — both pure here.
    const indirect = try declareCallbackHost(&f, "hostmod.apply", effects.pure, &pos0);
    var an = try Analysis.init(f.arena.allocator(), f.built, .{ .graph = f.graph, .hosts = indirect });
    try an.analyze();
    try testing.expect((try an.effectOf(call)).eql(effects.pure));

    // A listed position outside the call's arguments is refused too.
    const oob = [_]u32{5};
    const invalid = try declareCallbackHost(&f, "hostmod.apply", effects.pure, &oob);
    var an2 = try Analysis.init(f.arena.allocator(), f.built, .{ .graph = f.graph, .hosts = invalid });
    try an2.analyze();
    try testing.expect((try an2.effectOf(call)).eql(effects.top));

    // An extreme position must fail closed rather than wrap an index.
    const huge = [_]u32{std.math.maxInt(u32)};
    const extreme = try declareCallbackHost(&f, "hostmod.apply", effects.pure, &huge);
    var an_ext = try Analysis.init(f.arena.allocator(), f.built, .{ .graph = f.graph, .hosts = extreme });
    try an_ext.analyze();
    try testing.expect((try an_ext.effectOf(call)).eql(effects.top));

    // A `forbidden` attestation ignores any contract: the declared
    // summary applies verbatim, contract or not.
    const a = f.arena.allocator();
    const entries = try a.alloc(effects.HostEffects.Entry, f.built.hosts.items.len);
    for (f.built.hosts.items, 0..) |hb, i| {
        const target = std.mem.eql(u8, hb.key, "hostmod.apply");
        entries[i] = .{
            .host = @intCast(i),
            .summary = if (target) effects.may_trap else effects.pure,
            .stilla_execution = .forbidden,
            .callbacks = if (target) &oob else null,
        };
    }
    var an3 = try Analysis.init(a, f.built, .{ .graph = f.graph, .hosts = .{ .entries = entries } });
    try an3.analyze();
    try testing.expect((try an3.effectOf(call)).eql(effects.may_trap));
}

test "hir_effects: a callback argument with no provable target set is Top" {
    var f = try build("app", &.{
        .{ "hostmod", "fn apply(f: fn(int32) -> int32, x: int32) -> int32;" },
        .{
            "app",
            \\const hostmod = import("hostmod");
            \\fn run(cb: fn(int32) -> int32) -> int32 { hostmod.apply(cb, 3) }
            \\fn main() -> int32 { run(fn(x: int32) -> int32 { x }) }
        },
    });
    defer f.deinit();
    const call = findHostCall(&f).?;
    const pos0 = [_]u32{0};
    // `cb` is a λ parameter, not a `let` binding: resolution stops at the
    // binding site and the contract is refused, Top for the whole call
    // (never a truncated target set).
    const hosts = try declareCallbackHost(&f, "hostmod.apply", effects.pure, &pos0);
    var an = try Analysis.init(f.arena.allocator(), f.built, .{ .graph = f.graph, .hosts = hosts });
    try an.analyze();
    try testing.expect((try an.effectOf(call)).eql(effects.top));
}

/// The first `call` node whose callee is not a direct `fn_ref` — the
/// §9.2 indirect form the narrowing tests target.
fn findIndirectCall(f: *Fixture) ?hir.ExprId {
    const p = &f.built.program;
    for (p.exprs.items, 0..) |e, i| {
        if (e.op != call_op) continue;
        const ops = p.operands(@intCast(i));
        if (ops.len == 0) continue;
        const callee = p.node(ops[0]);
        if (callee.op == fn_ref_op or callee.op == lambda_op) continue;
        return @intCast(i);
    }
    return null;
}

test "hir_effects: an indirect call resolves a let-bound target and its branch set" {
    var f = try build("app", &.{.{
        "app",
        \\const c: int32 = 1;
        \\fn foo() -> int32 { c }
        \\fn bar() -> int32 { 2 }
        \\fn main(flag: bool) -> int32 {
        \\    let f = if (flag) { foo } else { bar };
        \\    f()
        \\}
    }});
    defer f.deinit();
    var an = try Analysis.init(f.arena.allocator(), f.built, .{ .graph = f.graph });
    try an.analyze();
    const call = findIndirectCall(&f).?;
    // The `let` names an `if` over two branches, so the target set is the
    // finite `{foo, bar}` and the call bound is their join — the
    // module-const read of `foo` survives, not Top.
    const want = try effects.join(f.arena.allocator(), try an.functionSummary(funcId(&f, "app.foo").?), try an.functionSummary(funcId(&f, "app.bar").?));
    const sum = try an.effectOf(call);
    try testing.expect(sum.eql(want));
    try testing.expect(!sum.eql(effects.top));
    try testing.expectEqual(@as(usize, 1), sum.accesses.accesses.len);
    switch (sum.accesses.accesses[0].resource) {
        .module_const => {},
        else => return error.TestUnexpectedResult,
    }
    try testing.expect((try an.validate(testing.allocator)) == null);
}

/// A source module whose `main` calls `t{n-1}` through a right-leaning
/// `if` chain — every `t_i` reads the same module constant, so any
/// subset-truncation of the target set would still yield `Read(c)`, and
/// only a genuine refusal yields `Top`.
fn indirectIfChainSource(n: usize) ![]const u8 {
    const a = testing.allocator;
    var buf = std.ArrayList(u8).empty;
    errdefer buf.deinit(a);
    try buf.appendSlice(a, "const c: int32 = 1;\n");
    for (0..n) |i| {
        const line = try std.fmt.allocPrint(a, "fn t{d}() -> int32 {{ c }}\n", .{i});
        defer a.free(line);
        try buf.appendSlice(a, line);
    }
    try buf.appendSlice(a, "fn main(flag: bool) -> int32 {\n    let f = ");
    for (0..n - 1) |i| {
        const piece = try std.fmt.allocPrint(a, "if (flag) {{ t{d} }} else {{ ", .{i});
        defer a.free(piece);
        try buf.appendSlice(a, piece);
    }
    const last = try std.fmt.allocPrint(a, "t{d}", .{n - 1});
    defer a.free(last);
    try buf.appendSlice(a, last);
    for (0..n - 1) |_| try buf.appendSlice(a, " }");
    try buf.appendSlice(a, ";\n    f()\n}\n");
    return buf.toOwnedSlice(a);
}

test "hir_effects: indirect target resolution is exact at the budget and Top one past it" {
    // Exactly `max_indirect_targets` distinct targets: resolvable.
    const at_budget = try indirectIfChainSource(max_indirect_targets);
    defer testing.allocator.free(at_budget);
    var f1 = try build("app", &.{.{ "app", at_budget }});
    defer f1.deinit();
    var an1 = try Analysis.init(f1.arena.allocator(), f1.built, .{ .graph = f1.graph });
    try an1.analyze();
    const call1 = findIndirectCall(&f1).?;
    const sum1 = try an1.effectOf(call1);
    try testing.expect(!sum1.eql(effects.top));
    try testing.expect(sum1.eql(try an1.functionSummary(funcId(&f1, "app.t0").?)));

    // One more target exceeds the budget: the whole call is `Top`. A
    // truncating resolver would instead return the first-N join, which
    // here is `Read(c)` — so this assertion is what pins "never cut the
    // set".
    const over_budget = try indirectIfChainSource(max_indirect_targets + 1);
    defer testing.allocator.free(over_budget);
    var f2 = try build("app", &.{.{ "app", over_budget }});
    defer f2.deinit();
    var an2 = try Analysis.init(f2.arena.allocator(), f2.built, .{ .graph = f2.graph });
    try an2.analyze();
    const call2 = findIndirectCall(&f2).?;
    try testing.expect((try an2.effectOf(call2)).eql(effects.top));
}

test "hir_effects: an escaped or parameter-bound callable stays Top" {
    var f = try build("app", &.{.{
        "app",
        \\struct Holder { f: fn() -> int32; }
        \\fn invoke(cb: fn() -> int32) -> int32 { cb() }
        \\fn call_field(h: Holder) -> int32 { (h.f)() }
    }});
    defer f.deinit();
    var an = try Analysis.init(f.arena.allocator(), f.built, .{ .graph = f.graph });
    try an.analyze();
    for ([_][]const u8{ "app.invoke", "app.call_field" }) |name| {
        const fid = funcId(&f, name).?;
        // Every indirect call in the body has no provable finite target:
        // a λ parameter, or a struct field the value escaped into.
        const found = try indirectCallInBody(&f, fid);
        const sum = try an.effectOf(found);
        try testing.expect(sum.eql(effects.top));
    }
    try testing.expect((try an.validate(testing.allocator)) == null);
}

/// The first non-`fn_ref` call inside one function body (asserting the
/// fixture actually contains one).
fn indirectCallInBody(f: *Fixture, fid: hir.FuncId) !hir.ExprId {
    const p = &f.built.program;
    var work = std.ArrayListUnmanaged(hir.ExprId).empty;
    defer work.deinit(f.arena.allocator());
    try work.append(f.arena.allocator(), f.built.funcs.items[fid].root);
    while (work.pop()) |id| {
        const n = p.node(id);
        if (n.op == call_op) {
            const ops = p.operands(id);
            if (ops.len > 0) {
                const callee = p.node(ops[0]);
                if (callee.op != fn_ref_op and callee.op != lambda_op) return id;
            }
        }
        for (p.operands(id)) |op| try work.append(f.arena.allocator(), op);
        for (p.regionsOf(id)) |r| try work.append(f.arena.allocator(), p.region(r).root);
    }
    return error.TestUnexpectedResult;
}

test "hir_effects: recursion through a let-bound fn_ref seeds may_diverge" {
    var f = try build("app", &.{.{
        "app",
        \\fn g(x: int32) -> int32 {
        \\    let f = g;
        \\    f(x)
        \\}
        \\fn main() -> int32 { g(1) }
    }});
    defer f.deinit();
    var an = try Analysis.init(f.arena.allocator(), f.built, .{ .graph = f.graph });
    try an.analyze();
    // The only self-call is indirect (`f(x)` through the `let`), so the
    // SCC `g -> g` edge can only come from the §9.2 resolution. Without
    // it the component is a singleton with no self-loop and the summary
    // would under-report divergence.
    const g = try an.functionSummary(funcId(&f, "app.g").?);
    try testing.expect(g.may_diverge);
    try testing.expect(!g.eql(effects.top));
    try testing.expect((try an.validate(testing.allocator)) == null);
}

test "hir_effects: a callback recursion is seeded may_diverge by the SCC fixpoint" {
    var f = try build("app", &.{
        .{ "hostmod", "fn apply(f: fn(int32) -> int32, x: int32) -> int32;" },
        .{
            "app",
            \\const hostmod = import("hostmod");
            \\fn g(x: int32) -> int32 { hostmod.apply(g, x) }
            \\fn main() -> int32 { g(1) }
        },
    });
    defer f.deinit();
    const pos0 = [_]u32{0};
    const hosts = try declareCallbackHost(&f, "hostmod.apply", effects.pure, &pos0);
    var an = try Analysis.init(f.arena.allocator(), f.built, .{ .graph = f.graph, .hosts = hosts });
    try an.analyze();
    // `g` reaches itself only through the host's callback argument, so
    // the call graph edge `g -> g` must come from the instantiated
    // contract; without it the SCC is a singleton with no self-loop and
    // the `Diverge` seed would be missed, under-reporting the summary.
    // The `!Top` half rejects a vacuous pass: a `callBound` that fell
    // back to `top` would also diverge.
    const g = try an.functionSummary(funcId(&f, "app.g").?);
    try testing.expect(g.may_diverge);
    try testing.expect(!g.eql(effects.top));
    try testing.expect((try an.validate(testing.allocator)) == null);
}

test "hir_effects: a registration-only contract charges the write, never the callback" {
    var f = try build("app", &.{
        .{ "hostmod", "fn store(f: fn(int32) -> int32) -> void;\nfn trigger() -> int32;" },
        .{
            "app",
            \\const hostmod = import("hostmod");
            \\const base: int32 = 7;
            \\fn inc(x: int32) -> int32 { x + base }
            \\fn main() -> int32 {
            \\    hostmod.store(inc);
            \\    hostmod.trigger()
            \\}
        },
    });
    defer f.deinit();
    const a = f.arena.allocator();
    // Storing the callable changes observable host state, so the
    // registration call must carry a write of its own — and the
    // callback's read is distinguishable from it.
    const store_write = try effects.summaryOf(a, &.{.{ .resource = .{ .host = 1 }, .mode = .write }});
    const entries = try a.alloc(effects.HostEffects.Entry, f.built.hosts.items.len);
    const empty = [_]u32{};
    for (f.built.hosts.items, 0..) |hb, i| {
        if (std.mem.eql(u8, hb.key, "hostmod.store")) {
            // Attests it stores the callable but executes nothing during
            // this invocation.
            entries[i] = .{ .host = @intCast(i), .summary = store_write, .stilla_execution = .may_execute, .callbacks = &empty };
        } else {
            // The trigger invokes the stored callable: it passes no
            // callable argument, so only an unspecified contract is
            // honest — and that is Top.
            entries[i] = .{ .host = @intCast(i), .summary = effects.pure, .stilla_execution = .may_execute };
        }
    }
    var an = try Analysis.init(a, f.built, .{ .graph = f.graph, .hosts = .{ .entries = entries } });
    try an.analyze();

    var saw_store = false;
    var saw_trigger = false;
    for (f.built.program.exprs.items, 0..) |e, i| {
        if (e.op != call_op) continue;
        const id: hir.ExprId = @intCast(i);
        const callee = f.built.program.node(f.built.program.operands(id)[0]);
        if (callee.payload != .func or callee.payload.func != .host) continue;
        const key = f.built.hosts.items[callee.payload.func.host].key;
        if (std.mem.eql(u8, key, "hostmod.store")) {
            // The registration call is exactly its own write: `inc`'s
            // module-const read is *not* charged to it, so a summary
            // that merely read `inc` would fail this equality.
            try testing.expect((try an.effectOf(id)).eql(store_write));
            try testing.expect((try an.effectOf(id)).accesses.accesses.len == 1);
            try testing.expectEqual(effects.EffectMode.write, (try an.effectOf(id)).accesses.accesses[0].mode);
            saw_store = true;
        } else if (std.mem.eql(u8, key, "hostmod.trigger")) {
            // The later invocation has no callable argument, so it is Top
            // even though the registration call was bounded.
            try testing.expect((try an.effectOf(id)).eql(effects.top));
            saw_trigger = true;
        }
    }
    try testing.expect(saw_store and saw_trigger);
    try testing.expect((try an.validate(testing.allocator)) == null);
}

// ---------------------------------------------------------------------------
// Full-expression cleanup registration (docs/effects.md §11.2)
// ---------------------------------------------------------------------------

/// Configure every host binding with a pure, non-reentrant contract so a
/// bodyless member contributes no effect of its own.
fn pureHostEntries(a: std.mem.Allocator, built: *hir.BuiltProgram) ![]effects.HostEffects.Entry {
    const entries = try a.alloc(effects.HostEffects.Entry, built.hosts.items.len);
    for (built.hosts.items, 0..) |_, i| {
        entries[i] = .{ .host = @intCast(i), .summary = effects.pure, .stilla_execution = .forbidden };
    }
    return entries;
}

test "hir_effects: a transferred Unique temporary contributes no cleanup" {
    var f = try build("app", &.{.{
        "app",
        \\struct Token { id: int32; drop(t) { let x = t.id; } }
        \\fn consume(move t: Token) -> int32;
        \\fn make(id: int32) -> Token { Token { id: id } }
        \\fn f(id: int32) -> int32 { consume(make(id)) }
    }});
    defer f.deinit();
    try testing.expect(f.built.program.cleanup_modeled);
    const a = f.arena.allocator();
    var an = try Analysis.init(a, f.built, .{ .graph = f.graph, .hosts = .{ .entries = try pureHostEntries(a, f.built) } });
    try an.analyze();
    var found = false;
    for (f.built.program.exprs.items, 0..) |e, i| {
        if (e.op != call_op) continue;
        const callee = f.built.program.node(f.built.program.operands(@intCast(i))[0]);
        if (callee.payload != .func or callee.payload.func != .host) continue;
        const id: hir.ExprId = @intCast(i);
        const arg = f.built.program.operands(id)[1];
        // The transferred argument is not a registered temporary, so the
        // footprint carries no cleanup — the MVP `cleanupFree` rejected
        // the subtree merely because it saw an owned Unique node.
        for (f.built.program.cleanup_tokens.items) |tk| {
            try testing.expect(tk.origin_expr != arg);
        }
        try testing.expect(try an.cleanupDiscardable(id));
        found = true;
        // (`isDiscardable` still fails: the ownership gate rejects the
        // `Consume` argument slot, independent of cleanup.)
    }
    try testing.expect(found);
    try testing.expect((try an.validate(testing.allocator)) == null);
}

test "hir_effects: a discarded Unique temporary is discardable through its modelled pure destructor" {
    var f = try build("app", &.{.{
        "app",
        \\struct Token { id: int32; drop(t) { let x = t.id; } }
        \\fn f(id: int32) -> int32 {
        \\    let _ = Token { id: id };
        \\    7
        \\}
    }});
    defer f.deinit();
    const a = f.arena.allocator();
    var an = try Analysis.init(a, f.built, .{ .graph = f.graph });
    try an.analyze();
    var found = false;
    for (f.built.program.exprs.items, 0..) |e, i| {
        const cap = (try an.capabilityOf(f.built.program.typeOf(e.ty))) orelse .unique;
        if (cap != .unique) continue;
        if (!std.mem.eql(u8, hir.registry.get(e.op).name, "struct_make")) continue;
        const id: hir.ExprId = @intCast(i);
        // Registered as a full-expression temporary ...
        var registered = false;
        for (f.built.program.cleanup_tokens.items) |tk| {
            if (tk.origin_expr == id) registered = true;
        }
        try testing.expect(registered);
        // ... with a modelled, discardable destructor (`drop` only reads
        // `t.id`), so the query goes through the footprint instead of the
        // MVP `cleanupFree` (which rejected every owned Unique subtree).
        try testing.expect(try an.cleanupDiscardable(id));
        try testing.expect(try an.isDiscardable(id));
        try testing.expect(try an.canFloatAsTree(id));
        found = true;
    }
    try testing.expect(found);
}

test "hir_effects: an observable destructor keeps a discarded temporary non-discardable" {
    var f = try build("app", &.{
        .{ "hostmod", "fn log(x: int32) -> void;" },
        .{
            "app",
            \\const hostmod = import("hostmod");
            \\struct Token { id: int32; drop(t) { hostmod.log(t.id); } }
            \\fn f(id: int32) -> int32 {
            \\    let _ = Token { id: id };
            \\    7
            \\}
        },
    });
    defer f.deinit();
    const a = f.arena.allocator();
    const write = try effects.summaryOf(a, &.{.{ .resource = .{ .host = 1 }, .mode = .write }});
    const entries = try a.alloc(effects.HostEffects.Entry, f.built.hosts.items.len);
    for (f.built.hosts.items, 0..) |_, i| entries[i] = .{ .host = @intCast(i), .summary = write, .stilla_execution = .forbidden };
    var an = try Analysis.init(a, f.built, .{ .graph = f.graph, .hosts = .{ .entries = entries } });
    try an.analyze();
    var found = false;
    for (f.built.program.exprs.items, 0..) |e, i| {
        const cap = (try an.capabilityOf(f.built.program.typeOf(e.ty))) orelse .unique;
        if (cap != .unique) continue;
        if (!std.mem.eql(u8, hir.registry.get(e.op).name, "struct_make")) continue;
        const id: hir.ExprId = @intCast(i);
        const ce = (try an.cleanupEffect(id)).?;
        try testing.expect(!effects.isPure(ce));
        try testing.expect(!effects.isObservableEffectFree(ce));
        try testing.expect(!(try an.isDiscardable(id)));
        found = true;
    }
    try testing.expect(found);
}

test "hir_effects: an unmodelled program's empty footprint never proves safety" {
    var f = try build("app", &.{.{
        "app",
        \\struct Token { id: int32; drop(t) { let x = t.id; } }
        \\fn make(id: int32) -> Token { Token { id: id } }
        \\fn f(id: int32) -> int32 {
        \\    let _ = make(id);
        \\    7
        \\}
    }});
    defer f.deinit();
    const a = f.arena.allocator();
    // Pretend the cleanup pass never ran: the (empty) table is unmodelled,
    // not a proof that there is no cleanup.
    f.built.program.cleanup_modeled = false;
    var an = try Analysis.init(a, f.built, .{ .graph = f.graph });
    try an.analyze();
    for (f.built.program.exprs.items, 0..) |e, i| {
        if (e.op != call_op) continue;
        const cap = (try an.capabilityOf(f.built.program.typeOf(e.ty))) orelse .unique;
        if (cap != .unique) continue;
        const id: hir.ExprId = @intCast(i);
        try testing.expect((try an.cleanupEffect(id)) == null);
        try testing.expect(!(try an.isDiscardable(id)));
        return;
    }
    return error.TestUnexpectedResult;
}

test "hir_effects: cleanup tokens satisfy their origin/type/FE invariants" {
    var f = try build("app", &.{.{
        "app",
        \\struct Token { id: int32; drop(t) { let x = t.id; } }
        \\fn make(id: int32) -> Token { Token { id: id } }
        \\fn f(id: int32) -> int32 {
        \\    let _ = make(id);
        \\    7
        \\}
    }});
    defer f.deinit();
    const pr = &f.built.program;
    try testing.expect(pr.cleanup_modeled);
    try testing.expect(pr.cleanup_tokens.items.len > 0);
    const a = f.arena.allocator();
    var next = std.AutoHashMapUnmanaged(hir.FullExprId, u32).empty;
    for (pr.cleanup_tokens.items) |tk| {
        try testing.expect(tk.origin_expr < pr.exprs.items.len);
        try testing.expect(tk.full_expr < pr.full_exprs.items.len);
        switch (tk.kind) {
            .full_expression => {
                // A registered temporary is never a binder read or an
                // explicit transfer, and its type is the node's own.
                try testing.expect(pr.node(tk.origin_expr).ty == tk.ty);
                const name = hir.registry.get(pr.node(tk.origin_expr).op).name;
                try testing.expect(!std.mem.eql(u8, name, "local"));
                try testing.expect(!std.mem.eql(u8, name, "move"));
                try testing.expect(!std.mem.eql(u8, name, "drop"));
            },
            .scope_end => |se| {
                // The anchor is the region root; the token's type is the
                // destroyed binding's.
                try testing.expect(pr.binder(se.binder).ty == tk.ty);
                try testing.expectEqual(pr.region(se.region).root, tk.origin_expr);
            },
        }
        // Registration indices within one FE are 0,1,2,… in list order.
        const gop = try next.getOrPut(a, tk.full_expr);
        if (!gop.found_existing) gop.value_ptr.* = 0;
        try testing.expectEqual(gop.value_ptr.*, tk.registration_index);
        gop.value_ptr.* += 1;
    }
    try testing.expect((try hir.validate(pr, f.built.funcs.items[f.built.funcs.items.len - 1].root, testing.allocator)) == null);
}

test "hir_effects: a scoped Unique binding's end-of-scope destructor enters observed_effect" {
    // `let t = make(id); t.id`: `t` is a Unique local never consumed (the
    // read is a borrow-only projection), so its scope-end destruction — a
    // `hostmod.log` write — is part of the let's observable effect
    // (docs/effects.md §11.2). Before the scope-end model, `cleanupEffect`
    // returned null → `Top` for this subtree; now the destructor is
    // registered and the derived queries see it.
    var f = try build("app", &.{
        .{ "hostmod", "fn log(x: int32) -> void;" },
        .{
            "app",
            \\const hostmod = import("hostmod");
            \\struct Token { id: int32; drop(t) { hostmod.log(t.id); } }
            \\fn make(id: int32) -> Token { Token { id: id } }
            \\fn f(id: int32) -> int32 {
            \\    let t = make(id);
            \\    t.id
            \\}
        },
    });
    defer f.deinit();
    const a = f.arena.allocator();
    const write = try effects.summaryOf(a, &.{.{ .resource = .{ .host = 1 }, .mode = .write }});
    const entries = try a.alloc(effects.HostEffects.Entry, f.built.hosts.items.len);
    for (f.built.hosts.items, 0..) |_, i| entries[i] = .{ .host = @intCast(i), .summary = write, .stilla_execution = .forbidden };
    var an = try Analysis.init(a, f.built, .{ .graph = f.graph, .hosts = .{ .entries = entries } });
    try an.analyze();
    const pr = &f.built.program;

    var let_id: ?hir.ExprId = null;
    var bind: ?hir.BinderId = null;
    for (pr.exprs.items, 0..) |e, i| {
        if (!std.mem.eql(u8, hir.registry.get(e.op).name, "let")) continue;
        const rid = pr.regionsOf(@intCast(i))[0];
        const params = pr.params(rid);
        if (params.len != 1) continue;
        const b = pr.binder(params[0]);
        if (b.mode == .borrow) continue;
        const cap = (try an.capabilityOf(f.built.program.typeOf(b.ty))) orelse .unique;
        if (cap == .copy) continue;
        let_id = @intCast(i);
        bind = params[0];
    }
    const id = let_id orelse return error.TestUnexpectedResult;
    const bd = bind.?;
    const rid = pr.regionsOf(id)[0];
    const root = pr.region(rid).root;

    // The binding owns a registered scope-end token anchored at its
    // region root, sharing the let's full expression.
    var registered = false;
    for (pr.cleanup_tokens.items) |tk| switch (tk.kind) {
        .full_expression => {},
        .scope_end => |se| if (se.binder == bd and se.region == rid) {
            try testing.expectEqual(root, tk.origin_expr);
            try testing.expectEqual(pr.node(id).full_expr, tk.full_expr);
            registered = true;
        },
    };
    try testing.expect(registered);

    // `cleanupEffect` and `observedEffect` now carry exactly the
    // destructor's write (previously null → `Top`); the observable
    // destruction keeps discardable / float false for the whole let.
    const ce = (try an.cleanupEffect(id)).?;
    try testing.expect(ce.eql(write));
    const oe = (try an.observedEffect(id)).?;
    try testing.expect(oe.eql(write));
    try testing.expect(!(try an.cleanupDiscardable(id)));
    try testing.expect(!(try an.isDiscardable(id)));
    try testing.expect(!(try an.canFloatAsTree(id)));
    try testing.expect((try an.validate(testing.allocator)) == null);
}

test "hir_effects: a purely-reading scope-end destructor makes the footprint discardable" {
    // The read-only destructor (`drop` only touches `t.id`) destroys
    // nothing observable: the registered scope-end token folds to `Pure`,
    // so `cleanupDiscardable` goes through where the old guard returned
    // null → `Top` (docs/effects.md §11.2). (The `let` itself stays
    // non-discardable: its init use is `Consume`, the ownership gate.)
    var f = try build("app", &.{.{
        "app",
        \\struct Token { id: int32; drop(t) { let x = t.id; } }
        \\fn make(id: int32) -> Token { Token { id: id } }
        \\fn f(id: int32) -> int32 {
        \\    let t = make(id);
        \\    t.id
        \\}
    }});
    defer f.deinit();
    const a = f.arena.allocator();
    var an = try Analysis.init(a, f.built, .{ .graph = f.graph });
    try an.analyze();
    const pr = &f.built.program;
    for (pr.exprs.items, 0..) |e, i| {
        if (!std.mem.eql(u8, hir.registry.get(e.op).name, "let")) continue;
        const rid = pr.regionsOf(@intCast(i))[0];
        const params = pr.params(rid);
        if (params.len != 1) continue;
        const b = pr.binder(params[0]);
        if (b.mode == .borrow) continue;
        const cap = (try an.capabilityOf(f.built.program.typeOf(b.ty))) orelse .unique;
        if (cap == .copy) continue; // the Unique binding, not the Copy one
        const id: hir.ExprId = @intCast(i);
        try testing.expect(try an.cleanupDiscardable(id));
        try testing.expect(!(try an.isDiscardable(id))); // ownership gate
        try testing.expect((try an.validate(testing.allocator)) == null);
        return;
    }
    return error.TestUnexpectedResult;
}

test "hir_effects: a function with an owned Unique parameter models its normal-exit destructor" {
    // `score(t: Token)` never consumes its owned parameter, so `t` is
    // destroyed at normal exit; the scope-end model folds that destructor
    // into the body summary (docs/effects.md §6.1). With a purely-reading
    // destructor the summary is now exactly `pure` — the old
    // `regionOwnsUnique` guard widened every such function to `Top`.
    var f = try build("app", &.{.{
        "app",
        \\struct Token { id: int32; drop(t) { let x = t.id; } }
        \\fn score(move t: Token) -> int32 { t.id }
    }});
    defer f.deinit();
    const a = f.arena.allocator();
    var an = try Analysis.init(a, f.built, .{ .graph = f.graph });
    try an.analyze();
    const fid = funcId(&f, "app.score").?;
    const sum = try an.lambdaBodySummary(f.built.funcs.items[fid].root);
    try testing.expect(effects.isTotal(sum));
    try testing.expect(effects.isPure(sum));

    // The observable destructor (a declared `hostmod.log` write) makes
    // the normal-exit cleanup observable: the summary is precise instead
    // of blanket `Top`, so it is total yet not effect-free.
    var g = try build("app", &.{
        .{ "hostmod", "fn log(x: int32) -> void;" },
        .{
            "app",
            \\const hostmod = import("hostmod");
            \\struct Token { id: int32; drop(t) { hostmod.log(t.id); } }
            \\fn score(move t: Token) -> int32 { t.id }
        },
    });
    defer g.deinit();
    const a2 = g.arena.allocator();
    const write = try effects.summaryOf(a2, &.{.{ .resource = .{ .host = 1 }, .mode = .write }});
    const entries = try a2.alloc(effects.HostEffects.Entry, g.built.hosts.items.len);
    for (g.built.hosts.items, 0..) |_, i| entries[i] = .{ .host = @intCast(i), .summary = write, .stilla_execution = .forbidden };
    var an2 = try Analysis.init(a2, g.built, .{ .graph = g.graph, .hosts = .{ .entries = entries } });
    try an2.analyze();
    const fid2 = funcId(&g, "app.score").?;
    const sum2 = try an2.lambdaBodySummary(g.built.funcs.items[fid2].root);
    try testing.expect(effects.isTotal(sum2));
    try testing.expect(!effects.isPure(sum2));
    try testing.expect(!effects.isObservableEffectFree(sum2));
    try testing.expect((try an2.validate(testing.allocator)) == null);
}

test "hir_effects: the validator rejects a mis-anchored scope-end token" {
    var f = try build("app", &.{.{
        "app",
        \\struct Token { id: int32; drop(t) { let x = t.id; } }
        \\fn make(id: int32) -> Token { Token { id: id } }
        \\fn f(id: int32) -> int32 {
        \\    let t = make(id);
        \\    t.id
        \\}
    }});
    defer f.deinit();
    const pr = &f.built.program;
    // Corrupt a scope-end token's full expression: a scope token must
    // ride the anchor region root's own FE (the outer FE whose end the
    // destruction fires at), so a foreign FE fails the boundary check.
    var corrupted = false;
    for (pr.cleanup_tokens.items) |*tk| switch (tk.kind) {
        .full_expression => {},
        .scope_end => {
            tk.full_expr = 0; // the seeded default FE, which owns no nodes
            corrupted = true;
        },
    };
    try testing.expect(corrupted);
    const msg = try hir.validate(pr, f.built.funcs.items[f.built.funcs.items.len - 1].root, testing.allocator);
    defer if (msg) |m| testing.allocator.free(m);
    try testing.expect(msg != null);
}

test "hir_effects: a list_make index read in range is trap-free, out of range stays Top" {
    // No source-level list indexing reaches `field_get` yet (docs/todo.md
    // item 19), so the shape is hand-built: it guards `fieldGetOwn`'s
    // bounds proof directly rather than through the parser.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var built = hir.BuiltProgram{ .arena = a, .program = try hir.Program.init(a) };
    const i32ty = meta.Type{ .primitive = .int32 };
    const inner = try a.create(meta.Type);
    inner.* = i32ty;
    const list_ty = meta.Type{ .list = inner };
    const c0 = try built.program.addExpr(.{ .op = hir.opId("const").?, .ty = try built.program.intern(i32ty), .payload = .{ .const_value = .{ .int = 10 } } });
    const c1 = try built.program.addExpr(.{ .op = hir.opId("const").?, .ty = try built.program.intern(i32ty), .payload = .{ .const_value = .{ .int = 20 } } });
    const lm = try built.program.addExpr(.{ .op = hir.opId("list_make").?, .ty = try built.program.intern(list_ty), .operands = try built.program.addOperands(&.{ c0, c1 }) });
    const in_range = try built.program.addExpr(.{ .op = hir.opId("field_get").?, .ty = try built.program.intern(i32ty), .operands = try built.program.addOperands(&.{lm}), .payload = .{ .field = 1 } });
    const oob = try built.program.addExpr(.{ .op = hir.opId("field_get").?, .ty = try built.program.intern(i32ty), .operands = try built.program.addOperands(&.{lm}), .payload = .{ .field = 2 } });
    const not_ctor = try built.program.addExpr(.{ .op = hir.opId("field_get").?, .ty = try built.program.intern(i32ty), .operands = try built.program.addOperands(&.{c0}), .payload = .{ .field = 0 } });
    var an = try Analysis.init(a, &built, .{});
    // The statically-known `list_make` length proves the in-range read
    // cannot trap (the bounds proof the projection rule consumes).
    try testing.expect(effects.isPure(an.fieldGetOwn(in_range)));
    // No proof in either direction: the conservative `Top` stands.
    try testing.expect(an.fieldGetOwn(oob).may_trap);
    try testing.expect(an.fieldGetOwn(not_ctor).may_trap);
}

test "hir_effects: the lattice instance changes a rewrite-legality verdict (docs/effects.md §5.7)" {
    var f = try buildWithHostIface("app", &.{.{
        "app",
        \\const sensor = import("sensor");
        \\fn main() -> void { }
        \\fn pick(x: int32) -> int32 { sensor.read(x) + sensor.peek(x) }
    }}, &.{.{
        "sensor",
        \\fn read(x: int32) -> int32;
        \\fn peek(x: int32) -> int32;
    }});
    defer f.deinit();
    const arena = f.arena.allocator();

    // Two host bindings, each declared (under a `forbidden` attestation)
    // as a read of its own host domain.
    const read_id = hostIndexOf(f.built, "sensor.read") orelse return error.TestUnexpectedResult;
    const peek_id = hostIndexOf(f.built, "sensor.peek") orelse return error.TestUnexpectedResult;
    const s_read = try effects.summaryOf(arena, &.{.{ .resource = .{ .host = 1 }, .mode = .read }});
    const s_peek = try effects.summaryOf(arena, &.{.{ .resource = .{ .host = 2 }, .mode = .read }});
    const entries = try arena.alloc(effects.HostEffects.Entry, f.built.hosts.items.len);
    for (0..f.built.hosts.items.len) |i| {
        entries[i] = .{
            .host = @intCast(i),
            .summary = if (i == read_id) s_read else if (i == peek_id) s_peek else effects.pure,
            .stilla_execution = .forbidden,
        };
    }

    // The `add` whose two operands are the two host calls.
    var target: ?hir.ExprId = null;
    for (f.built.program.exprs.items, 0..) |e, i| {
        if (!std.mem.eql(u8, hir.registry.get(e.op).name, "add.i32")) continue;
        const id: hir.ExprId = @intCast(i);
        if (f.built.program.operands(id).len == 2) {
            target = id;
            break;
        }
    }
    const id = target orelse return error.TestUnexpectedResult;

    // The default instance: two undeclared, distinct host domains are not
    // disjoint, so the swap is refused.
    var an = try Analysis.init(arena, f.built, .{ .graph = f.graph, .hosts = .{ .entries = entries } });
    try an.analyze();
    try testing.expect(!(try an.canSwapOperands(id, 0, 1)));

    // The same program under a `hierarchy` instance that places the two
    // domains under one root as sibling subtrees. They are provably
    // disjoint there, so the very same rewrite becomes legal — the
    // instance changes a legality verdict, not just a fingerprint. The
    // ancestor is a *host* domain, so the edge stays inside the
    // non-module-const namespace.
    const parents = [_]effects.ResourceOrder.Edge{
        .{ .child = .{ .host = 1 }, .parent = .{ .host = 9 } },
        .{ .child = .{ .host = 2 }, .parent = .{ .host = 9 } },
    };
    const provider = effects.Provider{
        .id = "stilla.test.sibling-hosts",
        .order = .{ .hierarchy = .{ .parents = &parents } },
    };
    var eng = try effects.Engine.init(arena, &provider, .{});
    // The hard cross-instance binding (docs/effects.md §5.7): re-binding
    // one program to a second instance is an explicit `reset`, never a
    // silent mix. The rows `an` interned under `flat` are dead weight.
    try f.built.program.effect_interner.reset(eng.descriptor_digest);
    var an2 = try Analysis.init(arena, f.built, .{ .graph = f.graph, .hosts = .{ .entries = entries }, .engine = &eng });
    try an2.analyze();
    try testing.expect(try an2.canSwapOperands(id, 0, 1));
}

/// The dense id of the host binding with `key`, or null.
fn hostIndexOf(built: *hir.BuiltProgram, key: []const u8) ?usize {
    for (built.hosts.items, 0..) |hb, i| {
        if (std.mem.eql(u8, hb.key, key)) return i;
    }
    return null;
}

test "hir_effects: an undeclared host call is the instance top, extra modes included (docs/effects.md §5.7, §13)" {
    var f = try buildWithHostIface("app", &.{.{
        "app",
        \\const sensor = import("sensor");
        \\fn main() -> void { let unused: int32 = sensor.read(1); }
    }}, &.{.{
        "sensor",
        \\fn read(x: int32) -> int32;
    }});
    defer f.deinit();
    const arena = f.arena.allocator();

    // A five-mode instance with *no* host declaration for `sensor.read`:
    // the call must be that instance's `top`, not the built-in-mode
    // `effects.top` (which would silently under-approximate the extra
    // mode).
    const provider = effects.Provider{ .id = "stilla.test.extra-mode", .modes = &effects.hierarchy_modes };
    var eng = try effects.Engine.init(arena, &provider, .{});
    var an = try Analysis.init(arena, f.built, .{ .graph = f.graph, .engine = &eng });
    try an.analyze();

    var found = false;
    for (f.built.program.exprs.items, 0..) |e, i| {
        if (e.op != call_op) continue;
        const s = try an.effectOf(@intCast(i));
        try testing.expect(s.accesses.wildcard(effects.mode_commute_update));
        try testing.expect(s.eql(eng.top()));
        try testing.expect(!s.eql(effects.top));
        found = true;
    }
    try testing.expect(found);

    // The same program under the default four-mode instance is the
    // built-in `top`, so the widening is the instance's, not a blanket
    // change. Binding one program to a second instance is an explicit
    // `reset` of the interner (docs/effects.md §5.7).
    const def_eng = try effects.Engine.initDefault(arena, .{});
    try f.built.program.effect_interner.reset(def_eng.descriptor_digest);
    var an2 = try Analysis.init(arena, f.built, .{ .graph = f.graph });
    try an2.analyze();
    for (f.built.program.exprs.items, 0..) |e, i| {
        if (e.op != call_op) continue;
        try testing.expect((try an2.effectOf(@intCast(i))).eql(effects.top));
    }
}

// ---------------------------------------------------------------------------
// Incremental function-summary cache (docs/effects.md §8.3)
// ---------------------------------------------------------------------------

test "hir_effects: an armed summary cache re-solves only dirty SCCs" {
    var f = try build("app", &.{.{
        "app",
        \\fn base() -> int32 { 1 }
        \\fn mid() -> int32 { base() + 2 }
        \\fn top() -> int32 { mid() + 3 }
    }});
    defer f.deinit();
    const a = f.arena.allocator();
    const cache = try SummaryCache.init(a);

    // First solve: the cache is unarmed, so this is a full derivation.
    var an = try Analysis.init(a, f.built, .{ .graph = f.graph, .cache = cache });
    try an.analyze();
    try testing.expect(cache.armed);
    try testing.expectEqual(@as(usize, 0), cache.dirtyCount());
    const full_transfers = cache.stats.node_transfers;
    const full_solved = cache.stats.components_solved;
    const full_rounds = cache.stats.fixpoint_rounds;
    const full_solves = cache.stats.solves;
    try testing.expect(full_transfers > 0);
    try testing.expect(full_solved > 1);

    // Nothing dirty: the second analysis reuses every cached value and
    // performs no transfer at all.
    var an_noop = try Analysis.init(a, f.built, .{ .graph = f.graph, .cache = cache });
    try an_noop.analyze();
    try testing.expectEqual(full_transfers, cache.stats.node_transfers);
    try testing.expectEqual(full_solved, cache.stats.components_solved);
    try testing.expectEqual(full_rounds, cache.stats.fixpoint_rounds);
    try testing.expectEqual(full_solves, cache.stats.solves);

    // Dirty one function: only its SCC (no caller's summary can move) is
    // re-solved, so every counter is strictly below the full solve.
    const mid = funcId(&f, "app.mid").?;
    try cache.markFunctionDirty(mid);
    var an2 = try Analysis.init(a, f.built, .{ .graph = f.graph, .cache = cache });
    try an2.analyze();
    try testing.expect(cache.stats.node_transfers - full_transfers < full_transfers);
    try testing.expect(cache.stats.components_solved - full_solved < full_solved);
    try testing.expect(cache.stats.fixpoint_rounds - full_rounds < full_rounds);
    // Every other SCC kept its cached value.
    try testing.expect(cache.stats.components_reused > 0);

    // The incremental result agrees with a fresh full solve, function by
    // function.
    var fresh = try Analysis.init(a, f.built, .{ .graph = f.graph });
    try fresh.analyze();
    for (f.built.funcs.items, 0..) |_, i| {
        const fid: hir.FuncId = @intCast(i);
        try testing.expect(an2.eng.eql(try an2.functionSummary(fid), try fresh.functionSummary(fid)));
    }
}

test "hir_effects: an incremental re-solve propagates a changed callee to callers" {
    // Only `leaf` is marked dirty; the may_trap it gains must still reach
    // `mid` and `top` through the incremental pass's caller propagation.
    var f = try build("app", &.{.{
        "app",
        \\fn leaf() -> int32 { 1 }
        \\fn mid() -> int32 { leaf() }
        \\fn top() -> int32 { mid() }
    }});
    defer f.deinit();
    const a = f.arena.allocator();
    const cache = try SummaryCache.init(a);
    var an = try Analysis.init(a, f.built, .{ .graph = f.graph, .cache = cache });
    try an.analyze();
    const leaf = funcId(&f, "app.leaf").?;
    const mid = funcId(&f, "app.mid").?;
    const top = funcId(&f, "app.top").?;
    try testing.expect((try an.functionSummary(top)).eql(effects.pure));

    // Rewrite `leaf`'s body to a trapping operation and mark it stale.
    const leaf_root = f.built.funcs.items[leaf].root;
    const leaf_body = bodyOf(&f.built.program, leaf_root);
    f.built.program.exprs.items[leaf_body].op = hir.opId("panic").?;
    try cache.markFunctionDirty(leaf);

    var an2 = try Analysis.init(a, f.built, .{ .graph = f.graph, .cache = cache });
    try an2.analyze();
    try testing.expect((try an2.functionSummary(leaf)).may_trap);
    try testing.expect((try an2.functionSummary(mid)).may_trap);
    try testing.expect((try an2.functionSummary(top)).may_trap);

    // The incremental result agrees with a fresh full solve.
    var fresh = try Analysis.init(a, f.built, .{ .graph = f.graph });
    try fresh.analyze();
    try testing.expect(an2.eng.eql(try an2.functionSummary(leaf), try fresh.functionSummary(leaf)));
    try testing.expect(an2.eng.eql(try an2.functionSummary(mid), try fresh.functionSummary(mid)));
    try testing.expect(an2.eng.eql(try an2.functionSummary(top), try fresh.functionSummary(top)));
}

test "hir_effects: a stale summary read before the solve fails closed" {
    var f = try build("app", &.{.{
        "app",
        \\fn leaf() -> int32 { 1 }
        \\fn mid() -> int32 { leaf() }
    }});
    defer f.deinit();
    const a = f.arena.allocator();
    const cache = try SummaryCache.init(a);
    var an = try Analysis.init(a, f.built, .{ .graph = f.graph, .cache = cache });
    try an.analyze();

    const leaf = funcId(&f, "app.leaf").?;
    const mid = funcId(&f, "app.mid").?;
    try cache.markFunctionDirty(mid);

    // An analysis that has not solved yet must not publish the stale
    // cached value of a dirty function; a clean sibling still reads its
    // cached value.
    var an2 = try Analysis.init(a, f.built, .{ .graph = f.graph, .cache = cache });
    try testing.expect(an2.cache.isDirty(mid));
    try testing.expect((try an2.functionSummary(mid)).eql(effects.top));
    try testing.expect((try an2.functionSummary(leaf)).eql(effects.pure));

    // After the solve the stale entry is gone and the value is precise.
    try an2.analyze();
    try testing.expect(!an2.cache.isDirty(mid));
    try testing.expect((try an2.functionSummary(mid)).eql(effects.pure));
}

test "hir_effects: drop-node identity survives incremental solves" {
    var f = try build("app", &.{.{
        "app",
        \\struct Token { id: int32; drop(t) { let x = t.id; } }
        \\fn use(id: int32) -> int32 {
        \\    let t = Token { id: id };
        \\    0
        \\}
        \\fn caller(id: int32) -> int32 { use(id) }
    }});
    defer f.deinit();
    const a = f.arena.allocator();
    const cache = try SummaryCache.init(a);
    var an = try Analysis.init(a, f.built, .{ .graph = f.graph, .cache = cache });
    try an.analyze();
    const nodes = cache.drop_key_of_node.items.len;
    try testing.expect(nodes > f.built.funcs.items.len + 1);

    // No new type is interned, so the persistent identity table keeps its
    // length and every cached node id still names the same type.
    try cache.markFunctionDirty(funcId(&f, "app.use").?);
    var an2 = try Analysis.init(a, f.built, .{ .graph = f.graph, .cache = cache });
    try an2.analyze();
    try testing.expectEqual(nodes, cache.drop_key_of_node.items.len);

    var fresh = try Analysis.init(a, f.built, .{ .graph = f.graph });
    try fresh.analyze();
    for (f.built.funcs.items, 0..) |_, i| {
        const fid: hir.FuncId = @intCast(i);
        try testing.expect(an2.eng.eql(try an2.functionSummary(fid), try fresh.functionSummary(fid)));
    }
}

test "hir_effects: a lattice-instance change un-arms the summary cache" {
    var f = try build("app", &.{.{
        "app",
        \\const base: int32 = 3;
        \\fn get() -> int32 { base }
    }});
    defer f.deinit();
    const a = f.arena.allocator();
    const cache = try SummaryCache.init(a);
    var an = try Analysis.init(a, f.built, .{ .graph = f.graph, .cache = cache });
    try an.analyze();
    try testing.expect(cache.armed);
    try testing.expect(cache.instance_digest != null);

    // A provider with a different identity has a different descriptor, so
    // the cache's values are stale in bulk: the next solve must be full.
    const provider = effects.Provider{ .id = "stilla.test.cache-instance" };
    var eng = try effects.Engine.init(a, &provider, .{});
    try testing.expect(eng.descriptor_digest != an.eng.descriptor_digest);
    try f.built.program.effect_interner.reset(eng.descriptor_digest);
    const reused_before = cache.stats.components_reused;

    var an2 = try Analysis.init(a, f.built, .{
        .graph = f.graph,
        .cache = cache,
        .engine = &eng,
    });
    try an2.analyze();
    try testing.expectEqual(reused_before, cache.stats.components_reused);
    try testing.expectEqual(eng.descriptor_digest, cache.instance_digest.?);
}
