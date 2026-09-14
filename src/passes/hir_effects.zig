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

pub const Summary = effects.Summary;
pub const Error = std.mem.Allocator.Error;

const lambda_op = hir.opId("lambda").?;
const fn_ref_op = hir.opId("fn_ref").?;
const call_op = hir.opId("call").?;
const drop_op = hir.opId("drop").?;
const let_op = hir.opId("let").?;
const local_op = hir.opId("local").?;
const if_op = hir.opId("if").?;
const match_op = hir.opId("match").?;
const seq_op = hir.opId("seq").?;
const move_op = hir.opId("move").?;
const borrow_op = hir.opId("borrow").?;

/// `never` primitive test — the bottom type (Core §13.2). `hir_build` owns
/// the same predicate but imports this module, so it is inlined here.
fn isNeverType(t: meta.Type) bool {
    return switch (t) {
        .primitive => |k| k == .never,
        else => false,
    };
}

/// Recursion bound for the `drop_effect` type walk (docs/effects.md
/// §11.1). Named-type recursion is cut by identity; this cap is the
/// safety net for an uninhabited non-regular instantiation chain, whose
/// summary falls back to the conservative `Top`.
const max_drop_type_depth = 64;

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

fn targetEq(a: ResolvedTarget, b: ResolvedTarget) bool {
    return switch (a) {
        .func => |f| switch (b) {
            .func => |g| f == g,
            else => false,
        },
        .host => |h| switch (b) {
            .host => |k| h == k,
            else => false,
        },
    };
}

/// Kosaraju pass 1: DFS finishing order over the caller→callee graph.
fn finishOrder(arena: std.mem.Allocator, adj: []const std.ArrayListUnmanaged(hir.FuncId)) Error![]hir.FuncId {
    const n = adj.len;
    const visited = try arena.alloc(bool, n);
    @memset(visited, false);
    var order = std.ArrayListUnmanaged(hir.FuncId).empty;
    var stack = std.ArrayListUnmanaged(struct { u32, usize }).empty;
    for (0..n) |s| {
        if (visited[s]) continue;
        visited[s] = true;
        try stack.append(arena, .{ @intCast(s), 0 });
        while (stack.items.len > 0) {
            const top = &stack.items[stack.items.len - 1];
            const v: hir.FuncId = top[0];
            if (top[1] < adj[v].items.len) {
                const w = adj[v].items[top[1]];
                top[1] += 1;
                if (!visited[w]) {
                    visited[w] = true;
                    try stack.append(arena, .{ w, 0 });
                }
            } else {
                try order.append(arena, v);
                _ = stack.pop();
            }
        }
    }
    return order.items;
}

/// Kosaraju pass 2: one DFS tree on the reversed graph is one SCC.
fn dfsCollect(
    arena: std.mem.Allocator,
    radj: []const std.ArrayListUnmanaged(hir.FuncId),
    start: hir.FuncId,
    seen: []bool,
    out: *std.ArrayListUnmanaged(hir.FuncId),
) Error!void {
    var stack = std.ArrayListUnmanaged(hir.FuncId).empty;
    try stack.append(arena, start);
    seen[start] = true;
    while (stack.pop()) |v| {
        try out.append(arena, v);
        for (radj[v].items) |w| {
            if (!seen[w]) {
                seen[w] = true;
                try stack.append(arena, w);
            }
        }
    }
}

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
    /// The module graph, used only to resolve the ownership class of
    /// generic named type instantiations. Without it, such a type is
    /// conservatively Unique.
    graph: ?*moduleinfo.ModuleGraph = null,
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

    pub fn init(arena: std.mem.Allocator, built: *hir.BuiltProgram, config: Config) Error!Analysis {
        const memo = try arena.alloc(?Summary, built.program.exprs.items.len);
        @memset(memo, null);
        const summary = try arena.alloc(Summary, built.funcs.items.len);
        @memset(summary, effects.pure);
        const known = try arena.alloc(bool, built.funcs.items.len);
        @memset(known, false);
        const comp_of = try arena.alloc(u32, built.funcs.items.len);
        @memset(comp_of, 0);
        const cur = try arena.alloc(Summary, built.funcs.items.len);
        @memset(cur, effects.pure);
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
        return .{
            .arena = arena,
            .built = built,
            .config = config,
            .hosts = merged,
            .memo = memo,
            .summary = summary,
            .known = known,
            .comp_of = comp_of,
            .solving = null,
            .cur = cur,
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

    fn p(self: *Analysis) *hir.Program {
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

    // -----------------------------------------------------------------
    // effect_transfer (docs/effects.md §6.1)
    // -----------------------------------------------------------------

    // -----------------------------------------------------------------
    // Precise drop_effect(T) (docs/effects.md §11.1)
    // -----------------------------------------------------------------

    /// `drop_effect(T)` — the interaction of destroying a value of type
    /// `ty`: the type's `drop` hook first, then its Unique fields in
    /// reverse declaration order, structurally through containers, and
    /// `Release` for host-backed opaque handles.
    ///
    /// Recursive types (a struct/union that reaches itself through a
    /// field) are solved as the least fixpoint of the destruction
    /// function: re-entering a type on the descent returns `pure`
    /// (lattice bottom). Because the may-summary of a cycle is the join
    /// over its finite unfoldings and joining the same accesses twice is
    /// idempotent, that bottom-on-reentry yields exactly the least
    /// fixpoint without an explicit iteration (docs/effects.md §11.1).
    /// No result is memoized: a value computed while a cycle was cut is
    /// an under-approximation that must not be reused at the top level.
    pub fn dropEffectOf(self: *Analysis, ty: meta.Type) Error!Summary {
        var visiting = std.ArrayListUnmanaged(meta.Type).empty;
        defer visiting.deinit(self.arena);
        return self.dropEffectInner(ty, &visiting);
    }

    fn dropEffectInner(self: *Analysis, ty: meta.Type, visiting: *std.ArrayListUnmanaged(meta.Type)) Error!Summary {
        // A Copy value's destruction has no interaction (§11.1), and a
        // Copy result short-circuits regardless of structure. A *stuck*
        // ownership (null) is not Copy: fall through to the structural
        // case, which is where `named`/`param` recursion lives.
        if (ty.ownership()) |ow| if (ow == .copy) return effects.pure;
        switch (ty) {
            .primitive => |k| return if (k == .any or k == .hostdata) effects.top else effects.pure,
            .module, .function, .cleanup => return effects.pure,
            .list, .box => |inner| return self.dropEffectInner(inner.*, visiting),
            .tuple => |elems| {
                var acc = effects.pure;
                var i = elems.len;
                while (i > 0) {
                    i -= 1;
                    acc = try effects.sequence(self.arena, acc, try self.dropEffectInner(elems[i], visiting));
                }
                return acc;
            },
            .param => return effects.top,
            .named => |n| {
                for (visiting.items) |v| if (meta.Type.eql(v, ty)) return effects.pure;
                if (visiting.items.len >= max_drop_type_depth) return effects.top;
                if (n.id >= self.built.types.len) return effects.top;
                try visiting.append(self.arena, ty);
                defer {
                    _ = visiting.pop();
                }
                switch (self.built.types[n.id]) {
                    .struct_ => |d| {
                        var acc = effects.pure;
                        if (d.drop) |dn| {
                            if (self.findFuncByName(dn)) |fid| acc = try effects.sequence(self.arena, acc, try self.functionSummary(fid));
                        }
                        var i = d.fields.len;
                        while (i > 0) {
                            i -= 1;
                            const ft = meta.substParams(self.arena, d.type_params, n.args, d.fields[i].type_);
                            if (try self.isCopyType(ft)) continue;
                            acc = try effects.sequence(self.arena, acc, try self.dropEffectInner(ft, visiting));
                        }
                        return acc;
                    },
                    .union_ => |d| {
                        var acc = effects.pure;
                        for (d.variants) |v| {
                            var vsum = effects.pure;
                            var i = v.payloads.len;
                            while (i > 0) {
                                i -= 1;
                                const pt = meta.substParams(self.arena, d.type_params, n.args, v.payloads[i]);
                                if (try self.isCopyType(pt)) continue;
                                vsum = try effects.sequence(self.arena, vsum, try self.dropEffectInner(pt, visiting));
                            }
                            acc = try effects.join(self.arena, acc, vsum);
                        }
                        return acc;
                    },
                    .opaque_ => |d| return self.hostRelease(d.host_id),
                    .unknown => return effects.top,
                }
            },
        }
    }

    /// The drop hook functions reachable from `ty` (the type's own hook
    /// plus every field/element hook), used to add the correct edges to
    /// the call graph so a hook's summary is solved before the `drop`
    /// that depends on it.
    fn collectTypeHooks(
        self: *Analysis,
        ty: meta.Type,
        visiting: *std.ArrayListUnmanaged(meta.Type),
        out: *std.ArrayListUnmanaged(hir.FuncId),
    ) Error!void {
        if (ty.ownership()) |ow| if (ow == .copy) return;
        switch (ty) {
            .list, .box => |inner| try self.collectTypeHooks(inner.*, visiting, out),
            .tuple => |elems| for (elems) |e| try self.collectTypeHooks(e, visiting, out),
            .primitive, .module, .function, .cleanup, .param => {},
            .named => |n| {
                // Full-instantiation key: an instantiation is the identity
                // (a type argument that changes on unrolling is a distinct
                // node in the type graph). The depth cap is the safety net
                // for an uninhabited non-regular instantiation chain.
                for (visiting.items) |v| if (meta.Type.eql(v, ty)) return;
                if (visiting.items.len >= max_drop_type_depth) return;
                if (n.id >= self.built.types.len) return;
                try visiting.append(self.arena, ty);
                defer {
                    _ = visiting.pop();
                }
                switch (self.built.types[n.id]) {
                    .struct_ => |d| {
                        if (d.drop) |dn| {
                            if (self.findFuncByName(dn)) |fid| {
                                if (!std.mem.containsAtLeastScalar(hir.FuncId, out.items, 1, fid)) try out.append(self.arena, fid);
                            }
                        }
                        for (d.fields) |f| try self.collectTypeHooks(meta.substParams(self.arena, d.type_params, n.args, f.type_), visiting, out);
                    },
                    .union_ => |d| for (d.variants) |v| for (v.payloads) |payload| try self.collectTypeHooks(meta.substParams(self.arena, d.type_params, n.args, payload), visiting, out),
                    .opaque_, .unknown => {},
                }
            },
        }
    }

    // -----------------------------------------------------------------
    // Module-constant init / teardown dependency check (docs/effects.md §7)
    // -----------------------------------------------------------------

    /// `Read(ModuleConst)` dependency check, replacing the checker's
    /// ad-hoc `InitOrder` walk (docs/effects.md §7, §14 再后 2). Two
    /// symmetric rules, both driven by the same function summaries:
    ///
    /// - **init**: an initializer (and every function it transitively
    ///   calls) may read only constants declared before it;
    /// - **teardown**: a Unique constant's destruction —
    ///   `drop_effect(type)`, the full hook + field/element chain — may
    ///   not read a constant destroyed earlier (declared later).
    ///
    /// Both rules compare declaration order within the constant's own
    /// module. Cross-module reads are always from already-initialized
    /// dependencies (the module graph is acyclic and topologically
    /// ordered), so checking the local module is complete. Returns null
    /// or the first violation message (owned by `allocator`).
    pub fn checkModuleDependencies(self: *Analysis, allocator: std.mem.Allocator) Error!?[]const u8 {
        for (0..self.built.modules.items.len) |mi| {
            const range = self.built.modules.items[mi].consts;
            const slice = self.built.consts.items[range.start..][0..range.len];
            for (slice) |c| {
                if (c.init) |root| {
                    if (try self.checkInitReads(c, root, allocator)) |msg| return msg;
                    if (try self.checkTeardownReads(c, allocator)) |msg| return msg;
                }
            }
        }
        return null;
    }

    fn checkInitReads(self: *Analysis, c: hir.ConstRecord, root: hir.ExprId, allocator: std.mem.Allocator) Error!?[]const u8 {
        const cur = self.initOrderOf(c) orelse return null;
        const s = try self.effectOf(root);
        return self.checkReadSet(c, cur, s, root, false, true, allocator);
    }

    fn checkTeardownReads(self: *Analysis, c: hir.ConstRecord, allocator: std.mem.Allocator) Error!?[]const u8 {
        const de = try self.dropEffectOf(c.type_);
        if (effects.isPure(de)) return null;
        const cur = self.initOrderOf(c) orelse return null;
        // Attribute direct reads / calls to the type's own hook body when
        // it has one; nested field hooks fall back to the generic form.
        var origin: ?hir.ExprId = null;
        if (c.type_ == .named and c.type_.named.id < self.built.types.len) {
            switch (self.built.types[c.type_.named.id]) {
                .struct_ => |d| if (d.drop) |dn| {
                    if (self.findFuncByName(dn)) |fid| origin = self.built.funcs.items[fid].root;
                },
                else => {},
            }
        }
        // An unknown read set is rejected for a nominal type (its
        // destruction is structural and a wildcard can only come from an
        // unmodelled indirect call). For `any`/`hostdata`/unresolved
        // named types the wildcard is the §11.1 "contents unknown" gap,
        // which cannot be attributed to a specific constant — the same
        // position the replaced AST walk took.
        const reject_unknown = self.typeIsNominal(c.type_);
        return self.checkReadSet(c, cur, de, origin orelse 0, true, reject_unknown, allocator);
    }

    fn typeIsNominal(self: *Analysis, ty: meta.Type) bool {
        if (ty != .named) return false;
        const id = ty.named.id;
        if (id >= self.built.types.len) return false;
        return switch (self.built.types[id]) {
            .struct_, .union_ => true,
            .opaque_, .unknown => false,
        };
    }

    /// Apply the declaration-order rule to every module-const read in
    /// `s` (docs/effects.md §7). `c` owns the read; `root` is used only
    /// for diagnostic attribution (0 = none).
    fn checkReadSet(
        self: *Analysis,
        c: hir.ConstRecord,
        cur: u32,
        s: Summary,
        root: hir.ExprId,
        teardown: bool,
        reject_unknown: bool,
        allocator: std.mem.Allocator,
    ) Error!?[]const u8 {
        if (reject_unknown and s.accesses.all[@intFromEnum(effects.EffectMode.read)]) {
            // An unknown read set may target any constant, including a
            // later one or this constant itself (docs/effects.md §7.3,
            // §9.4) — reject on the first initialized sibling.
            const range = self.built.modules.items[c.module].consts;
            for (self.built.consts.items[range.start..][0..range.len]) |other| {
                if (other.init == null) continue;
                return self.readDiag(c, other.name, true, root, teardown, allocator);
            }
            return null;
        }
        for (s.accesses.accesses) |a| {
            if (a.mode != .read) continue;
            const d = switch (a.resource) {
                .module_const => |cid| cid,
                else => continue,
            };
            if (d >= self.built.consts.items.len) continue;
            const dc = self.built.consts.items[d];
            if (dc.module != c.module) continue; // cross-module reads are ordered by the graph
            const dord = self.initOrderOf(dc) orelse continue;
            if (dord < cur) continue;
            return self.readDiag(c, dc.name, dord == cur, root, teardown, allocator);
        }
        return null;
    }

    fn readDiag(
        self: *Analysis,
        c: hir.ConstRecord,
        read_name: []const u8,
        self_read: bool,
        root: hir.ExprId,
        teardown: bool,
        allocator: std.mem.Allocator,
    ) Error!?[]const u8 {
        const callee = if (root != 0) self.attributingCallee(root) else null;
        if (teardown) {
            if (callee) |caller| {
                return try std.fmt.allocPrint(allocator, "drop hook of module constant '{s}' calls '{s}', which reads module constant '{s}' declared later (Core §5)", .{ c.name, caller, read_name });
            }
            return try std.fmt.allocPrint(allocator, "drop hook of module constant '{s}' reads '{s}' declared later (Core §5)", .{ c.name, read_name });
        }
        if (callee) |caller| {
            return try std.fmt.allocPrint(allocator, "module constant initializer calls '{s}', which reads module constant '{s}' declared later (Core §5)", .{ caller, read_name });
        }
        if (self_read) {
            return try std.fmt.allocPrint(allocator, "module constant initializer reads '{s}' before it is initialized (Core §5)", .{read_name});
        }
        return try std.fmt.allocPrint(allocator, "module constant initializer reads '{s}' declared later (Core §5)", .{read_name});
    }

    /// The name of the first directly-called local function reachable
    /// from `root` whose summary is non-pure. The old AST walk reported
    /// the outermost call that introduced a transitive read; this
    /// preserves that diagnostic shape (attribution only, never the
    /// legality decision).
    fn attributingCallee(self: *Analysis, root: hir.ExprId) ?[]const u8 {
        const pr = self.p();
        var work = std.ArrayListUnmanaged(hir.ExprId).empty;
        defer work.deinit(self.arena);
        work.append(self.arena, root) catch return null;
        while (work.pop()) |id| {
            const n = pr.node(id);
            if (n.op == call_op) {
                const ops = pr.operands(id);
                if (ops.len > 0) {
                    const cn = pr.node(ops[0]);
                    if (cn.op == fn_ref_op and cn.payload == .func) {
                        switch (cn.payload.func) {
                            .func => |fid| {
                                if (fid < self.built.funcs.items.len and self.known[fid] and !effects.isPure(self.summary[fid])) {
                                    return self.built.funcs.items[fid].name;
                                }
                            },
                            .host => {},
                        }
                    }
                }
            }
            for (pr.operands(id)) |op| work.append(self.arena, op) catch return null;
            for (pr.regionsOf(id)) |r| work.append(self.arena, pr.region(r).root) catch return null;
        }
        return null;
    }

    /// The declaration-order rank of `c` among the initialized constants
    /// of its own module (uninitialized / module-valued consts are not
    /// part of the schedule). Null when `c` has no initializer.
    fn initOrderOf(self: *Analysis, c: hir.ConstRecord) ?u32 {
        const range = self.built.modules.items[c.module].consts;
        var k: u32 = 0;
        for (self.built.consts.items[range.start..][0..range.len]) |other| {
            if (other.init == null) continue;
            if (std.mem.eql(u8, other.key, c.key)) return k;
            k += 1;
        }
        return null;
    }

    fn isCopyType(self: *Analysis, ty: meta.Type) Error!bool {
        const cap = try self.capabilityOf(ty) orelse return false;
        return cap == .copy;
    }

    fn findFuncByName(self: *Analysis, name: []const u8) ?hir.FuncId {
        for (self.built.funcs.items, 0..) |rec, i| {
            if (std.mem.eql(u8, rec.name, name)) return @intCast(i);
        }
        return null;
    }

    /// A host-backed opaque handle's destruction is a `Release` of its
    /// host domain (docs/effects.md §11.1). The domain id is a stable
    /// hash of the host identity; a collision only merges two release
    /// domains, which conservatively adds conflicts, never removes them.
    fn hostRelease(self: *Analysis, h: meta.HostTypeId) Error!Summary {
        var wh = std.hash.Wyhash.init(0);
        wh.update(h.host_module);
        wh.update(h.type_name);
        const domain: effects.HostDomainId = @truncate(wh.final());
        return effects.summaryOf(self.arena, &.{.{
            .resource = .{ .host = domain },
            .mode = .release,
        }});
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
        if (e.access_hops.len > 0) return effects.top;
        const d = hir.registry.get(e.op);
        switch (d.transfer) {
            .atom => return d.own_effect,
            .lambda => return d.own_effect,
            .strict_ltr => {
                var acc = d.own_effect;
                for (pr.operands(id)) |op| {
                    acc = try effects.sequence(self.arena, acc, try self.effectOf(op));
                }
                return acc;
            },
            .field_get => {
                var acc = self.fieldGetOwn(id);
                for (pr.operands(id)) |op| {
                    acc = try effects.sequence(self.arena, acc, try self.effectOf(op));
                }
                return acc;
            },
            .let_ => {
                var acc = d.own_effect;
                for (pr.operands(id)) |op| {
                    acc = try effects.sequence(self.arena, acc, try self.effectOf(op));
                }
                for (pr.regionsOf(id)) |r| {
                    // The region's pattern is not an HIR node: a list
                    // pattern's element reads (`read_index`/`split_list`,
                    // cfg may_trap) must be sequenced here explicitly.
                    if (pr.region(r).pattern) |pt| {
                        if (self.patternMayTrap(pt)) acc = try effects.sequence(self.arena, acc, effects.may_trap);
                    }
                    acc = try effects.sequence(self.arena, acc, try self.effectOf(pr.region(r).root));
                }
                return acc;
            },
            .branch => {
                // if / and / or: cond first, then one of two lazy regions.
                var acc = d.own_effect;
                var alt = effects.pure;
                for (pr.operands(id)) |op| {
                    acc = try effects.sequence(self.arena, acc, try self.effectOf(op));
                }
                for (pr.regionsOf(id)) |r| {
                    alt = try effects.join(self.arena, alt, try self.effectOf(pr.region(r).root));
                }
                return effects.sequence(self.arena, acc, alt);
            },
            .match => {
                var acc = d.own_effect;
                var arms = effects.pure;
                for (pr.operands(id)) |op| {
                    acc = try effects.sequence(self.arena, acc, try self.effectOf(op));
                }
                for (pr.regionsOf(id)) |r| {
                    // An arm's pattern test precedes its body: sequence the
                    // may-trap (list patterns) explicitly rather than
                    // joining it. Values coincide today (may-formula), but
                    // the semantic role is sequence (docs/effects.md §5.4).
                    var arm = effects.pure;
                    if (pr.region(r).pattern) |pt| {
                        if (self.patternMayTrap(pt)) arm = try effects.sequence(self.arena, arm, effects.may_trap);
                    }
                    arm = try effects.sequence(self.arena, arm, try self.effectOf(pr.region(r).root));
                    arms = try effects.join(self.arena, arms, arm);
                }
                return effects.sequence(self.arena, acc, arms);
            },
            .call => {
                const ops = pr.operands(id);
                var acc = d.own_effect;
                if (ops.len > 0) {
                    acc = try effects.sequence(self.arena, acc, try self.effectOf(ops[0]));
                    for (ops[1..]) |arg| {
                        acc = try effects.sequence(self.arena, acc, try self.effectOf(arg));
                    }
                    acc = try effects.sequence(self.arena, acc, try self.callBound(ops));
                }
                return acc;
            },
            .drop_effect => {
                var acc = d.own_effect;
                const ops = pr.operands(id);
                if (ops.len > 0) {
                    acc = try effects.sequence(self.arena, acc, try self.dropEffectOf(pr.node(ops[0]).ty));
                    acc = try effects.sequence(self.arena, acc, try self.effectOf(ops[0]));
                }
                return acc;
            },
            .module_const => {
                const cid = switch (e.payload) {
                    .module_const => |c| c,
                    else => return effects.top,
                };
                var raw = [_]effects.EffectAccess{.{
                    .resource = .{ .module_const = cid },
                    .mode = .read,
                }};
                return effects.summaryOf(self.arena, &raw);
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
        if (ops.len == 0) return effects.top;
        return switch (pr.node(ops[0]).ty) {
            .named, .tuple => effects.pure,
            // A list index read lowers to a bounds-checked `read_index`
            // and may trap (docs/effects.md §14 hidden-operation audit).
            // A `list_make` base with the payload index inside its
            // operand list is the one shape whose length is statically
            // known, so the read is provably in range and cannot trap —
            // the bounds proof the projection rule consumes (hir.md
            // §8.3). Any other list base keeps the conservative `Top`.
            .list => blk: {
                if (!std.mem.eql(u8, hir.registry.get(pr.node(ops[0]).op).name, "list_make")) break :blk effects.top;
                if (@as(usize, pr.node(id).payload.field) >= pr.operands(ops[0]).len) break :blk effects.top;
                break :blk effects.pure;
            },
            else => effects.top,
        };
    }

    /// The effect of *calling* the value `callee` evaluates to
    /// (docs/effects.md §6.1 `effect_bound`), distinct from `effects(callee)`.
    ///
    /// An inline λ is the one special case (its body is not a `fn_ref`
    /// target); every other callee — including a direct `fn_ref` — goes
    /// through the local target narrowing of docs/effects.md §9.2, which
    /// resolves a literal `fn_ref` to its singleton set. When narrowing
    /// yields no finite target set the result is the full `top` (§9.1).
    pub fn effectBound(self: *Analysis, callee: hir.ExprId) Error!Summary {
        if (self.p().node(callee).op == lambda_op) return self.lambdaBodySummary(callee);
        var targets = std.ArrayListUnmanaged(ResolvedTarget).empty;
        defer targets.deinit(self.arena);
        if (try self.resolveTargets(callee, &targets)) {
            if (targets.items.len > 0) {
                var acc: ?Summary = null;
                for (targets.items) |t| {
                    const b = try self.targetBound(t);
                    acc = if (acc) |a| try effects.join(self.arena, a, b) else b;
                }
                return acc.?;
            }
        }
        return effects.top;
    }

    /// The context-free `effect_bound` of one resolved target
    /// (docs/effects.md §6.1, §13): a function / λ record reads its
    /// finalized (or in-progress) summary; a host binding with no
    /// declaration is the full `top`, and a declaration is honoured only
    /// as far as `HostEffects.Entry.effectiveSummary` allows. The call-site
    /// refinement (callback parameterization) lives in `targetCallBound`.
    fn targetBound(self: *Analysis, t: ResolvedTarget) Error!Summary {
        return switch (t) {
            .func => |fid| self.functionSummary(fid),
            .host => |hb| self.hosts.lookup(hb) orelse effects.top,
        };
    }

    /// The provable finite target set of an indirect callee
    /// (docs/effects.md §9.2), demand-driven and budgeted.
    ///
    /// Traces the callee value backwards along the *local* binding chain
    /// the builder emits: a literal `fn_ref`, a `let`-bound local, the
    /// regions of an `if` / `match`, a `seq`'s forwarded last operand, and
    /// a `move` / `borrow` wrapper. Everything else is a boundary and
    /// returns false (→ `Top` at every caller): a function / λ parameter,
    /// a match-arm or destructuring binding, a `field_get` (the value
    /// escaped into a structure), any `call` / `module_const` result, a
    /// value-position module chain, an `any_cast` recovery. That is also
    /// the "no cross-function boundary, no escape path" rule: the walk
    /// only follows binding chains and stops at any other binding site.
    ///
    /// The budget is a precision limit, never a truncation: exceeding
    /// `max_indirect_targets` distinct targets or `max_indirect_steps`
    /// node visits returns false, it never returns the first N targets.
    /// `collectCallees` drives the same function, so the call graph always
    /// sees exactly the target set the summaries use; this never reads an
    /// effect summary, so graph construction has no circularity.
    fn resolveTargets(self: *Analysis, callee: hir.ExprId, out: *std.ArrayListUnmanaged(ResolvedTarget)) Error!bool {
        const pr = self.p();
        var work = std.ArrayListUnmanaged(hir.ExprId).empty;
        defer work.deinit(self.arena);
        try work.append(self.arena, callee);
        var steps: usize = 0;
        while (work.pop()) |id| {
            steps += 1;
            if (steps > max_indirect_steps) return false;
            const n = pr.node(id);
            // A value-position module chain runs module initialization, an
            // effect this model does not represent (docs/effects.md §14),
            // so it is a boundary — same as in `compute`.
            if (n.access_hops.len > 0) return false;
            if (n.op == fn_ref_op) {
                switch (n.payload) {
                    .func => |fr| {
                        const t: ResolvedTarget = switch (fr) {
                            .func => |fid| .{ .func = fid },
                            .host => |hb| .{ .host = hb },
                        };
                        if (!try self.addTarget(out, t)) return false;
                    },
                    else => return false,
                }
            } else if (n.op == local_op) {
                const bind = switch (n.payload) {
                    .binder => |b| b,
                    else => return false,
                };
                if (bind >= self.binder_init.len) return false;
                const initializer = self.binder_init[bind];
                if (initializer == hir.no_expr) return false;
                try work.append(self.arena, initializer);
            } else if (n.op == if_op or n.op == match_op) {
                for (pr.regionsOf(id)) |r| try work.append(self.arena, pr.region(r).root);
            } else if (n.op == seq_op) {
                const ops = pr.operands(id);
                if (ops.len == 0) return false;
                try work.append(self.arena, ops[ops.len - 1]);
            } else if (n.op == move_op or n.op == borrow_op) {
                const ops = pr.operands(id);
                if (ops.len != 1) return false;
                try work.append(self.arena, ops[0]);
            } else {
                return false;
            }
        }
        return true;
    }

    /// Add one target to the set, deduplicated, refusing (never
    /// truncating) once the set would exceed `max_indirect_targets`.
    fn addTarget(self: *Analysis, out: *std.ArrayListUnmanaged(ResolvedTarget), t: ResolvedTarget) Error!bool {
        for (out.items) |x| if (targetEq(x, t)) return true;
        if (out.items.len >= max_indirect_targets) return false;
        try out.append(self.arena, t);
        return true;
    }

    /// `effect_bound` of a *call site* (docs/effects.md §6.1, §13).
    ///
    /// The callee's target set is resolved once (docs/effects.md §9.2);
    /// the site's bound is the join over the targets. A `may_execute` host
    /// binding with an exhaustive callback contract is bounded by
    /// `own ⊔ ⨆ effect_bound(target_i)` — the contract attests the
    /// execution happens synchronously, during this invocation, and only
    /// through the listed argument positions, so a binding that stores a
    /// callable for a later call cannot use it.
    ///
    /// Any unresolved callee, a missing declaration, an out-of-range
    /// position, or a callback argument with no provable finite target set
    /// makes the site `Top`. The same target set feeds `collectCallees`, so
    /// this only ever reads finalized or in-progress SCC facts.
    fn callBound(self: *Analysis, ops: []const hir.ExprId) Error!Summary {
        if (ops.len == 0) return effects.top;
        var targets = std.ArrayListUnmanaged(ResolvedTarget).empty;
        defer targets.deinit(self.arena);
        if (try self.resolveTargets(ops[0], &targets)) {
            if (targets.items.len > 0) {
                var acc: ?Summary = null;
                for (targets.items) |t| {
                    const b = try self.targetCallBound(t, ops);
                    acc = if (acc) |a| try effects.join(self.arena, a, b) else b;
                }
                return acc.?;
            }
        }
        // Includes the λ-callee white-box case `resolveTargets` does not
        // model; every other unresolved callee is `Top` there.
        return self.effectBound(ops[0]);
    }

    /// One resolved target's `effect_bound` at a call site. A `may_execute`
    /// host with a callback contract is the only case richer than
    /// `targetBound`; `ops[1..]` are the call's arguments.
    fn targetCallBound(self: *Analysis, t: ResolvedTarget, ops: []const hir.ExprId) Error!Summary {
        switch (t) {
            .func => |fid| return self.functionSummary(fid),
            .host => |hb| {
                const entry = self.hosts.lookupEntry(hb) orelse return effects.top;
                if (entry.stilla_execution != .may_execute) return entry.effectiveSummary();
                const positions = entry.callbacks orelse return entry.effectiveSummary();
                var acc = entry.summary;
                for (positions) |pos| {
                    // Bounds-check before widening: `pos + 1` would overflow
                    // on a 32-bit target when `pos` is `maxInt(u32)`, and a
                    // wrapped index is a wrong answer, not a conservative
                    // one. Arg 0 is ops[1], so a valid position is
                    // `< ops.len - 1`.
                    if (pos >= ops.len - 1) return effects.top;
                    const bound = try self.callbackBound(ops[@as(usize, pos) + 1]) orelse return effects.top;
                    acc = try effects.join(self.arena, acc, bound);
                }
                return acc;
            },
        }
    }

    /// `effect_bound` of a callable value passed as an argument
    /// (docs/effects.md §13 callback parameterization), for the local
    /// target narrowing of §9.2. Null when no provable finite target set
    /// exists, which the contract path maps to `Top` for the whole call
    /// (never a truncated set). A value-position module chain would run
    /// module initialization, so it is null too.
    fn callbackBound(self: *Analysis, arg: hir.ExprId) Error!?Summary {
        const n = self.p().node(arg);
        if (n.access_hops.len > 0) return null;
        if (n.op == lambda_op) return try self.lambdaBodySummary(arg);
        var targets = std.ArrayListUnmanaged(ResolvedTarget).empty;
        defer targets.deinit(self.arena);
        if (try self.resolveTargets(arg, &targets)) {
            if (targets.items.len > 0) {
                var acc: ?Summary = null;
                for (targets.items) |t| {
                    const b = try self.targetBound(t);
                    acc = if (acc) |a| try effects.join(self.arena, a, b) else b;
                }
                return acc.?;
            }
        }
        return null;
    }

    // -----------------------------------------------------------------
    // Function summaries
    // -----------------------------------------------------------------

    /// A finalized (or in-progress) function summary. `Top` for an
    /// out-of-range id (missing body). While its SCC is being solved a
    /// member reads the in-progress approximation; every other id reads
    /// the finalized value (docs/effects.md §8.2).
    pub fn functionSummary(self: *Analysis, fid: hir.FuncId) Error!Summary {
        if (fid >= self.built.funcs.items.len) return effects.top;
        if (self.solving) |s| {
            if (self.comp_of[fid] == s) return self.cur[fid];
        }
        if (!self.known[fid]) return effects.top;
        return self.summary[fid];
    }

    // -----------------------------------------------------------------
    // Function-summary SCC least fixpoint (docs/effects.md §8.2)
    // -----------------------------------------------------------------

    /// Solve the whole program's function summaries.
    ///
    /// The call graph is built over the analysis' actual targets: a `call`
    /// whose callee operand is a resolved `fn_ref` to a function record.
    /// Indirect / host / unknown targets do not enter the graph (`Top`,
    /// §9.1). SCCs are then processed callee-first, each solved by Kleene
    /// iteration from `Bottom`; a recursive SCC is seeded `Diverge`
    /// (§8.2 "从 Bottom 迭代本身不能发现发散"). Rounds use a simultaneous
    /// update (`next[f]` computed from one approximation, then assigned),
    /// so the iteration is monotone and converges on the finite lattice.
    fn solveSummaries(self: *Analysis) Error!void {
        const n = self.built.funcs.items.len;
        self.solving = null;
        @memset(self.memo, null);
        @memset(self.known, false);
        @memset(self.summary, effects.pure);
        if (n == 0) return;

        // 1. Call graph (callee ids, deduplicated per caller).
        const adj = try self.arena.alloc(std.ArrayListUnmanaged(hir.FuncId), n);
        for (adj) |*a| a.* = .empty;
        for (0..n) |i| try self.collectCallees(@intCast(i), &adj[i]);

        // 2. SCCs by Kosaraju: finish order on G, then DFS on G^T in
        //    reverse finish order.
        var radj = try self.arena.alloc(std.ArrayListUnmanaged(hir.FuncId), n);
        for (radj) |*a| a.* = .empty;
        for (0..n) |u| {
            for (adj[u].items) |v| try radj[v].append(self.arena, @intCast(u));
        }
        const order = try finishOrder(self.arena, adj);
        var comps = std.ArrayListUnmanaged(std.ArrayListUnmanaged(hir.FuncId)).empty;
        const seen = try self.arena.alloc(bool, n);
        @memset(seen, false);
        var i = order.len;
        while (i > 0) {
            i -= 1;
            const v = order[i];
            if (seen[v]) continue;
            var comp = std.ArrayListUnmanaged(hir.FuncId).empty;
            try dfsCollect(self.arena, radj, v, seen, &comp);
            const cid: u32 = @intCast(comps.items.len);
            for (comp.items) |m| self.comp_of[m] = cid;
            try comps.append(self.arena, comp);
        }

        // 3. Process components callee-first. Kosaraju's second pass
        //    discovers source SCCs of G (uncalled roots) first, i.e.
        //    callers before callees; reverse that.
        var c = comps.items.len;
        while (c > 0) {
            c -= 1;
            try self.solveComponent(comps.items[c].items, adj);
        }
    }

    /// Every `call` target in `fid`'s body that the local narrowing of
    /// docs/effects.md §9.2 can resolve to a function record, plus the
    /// designated callback arguments of a host contract. The graph must
    /// see exactly the target set the summaries consume (`callBound`),
    /// otherwise a recursion that runs through a `let`-bound fn-ref would
    /// miss the SCC `Diverge` seed (docs/effects.md §8.2).
    fn collectCallees(self: *Analysis, fid: hir.FuncId, out: *std.ArrayListUnmanaged(hir.FuncId)) Error!void {
        const pr = self.p();
        var work = std.ArrayListUnmanaged(hir.ExprId).empty;
        defer work.deinit(self.arena);
        try work.append(self.arena, self.built.funcs.items[fid].root);
        while (work.pop()) |id| {
            const node = pr.node(id);
            if (node.op == call_op) {
                const ops = pr.operands(id);
                if (ops.len > 0) {
                    var targets = std.ArrayListUnmanaged(ResolvedTarget).empty;
                    defer targets.deinit(self.arena);
                    if (try self.resolveTargets(ops[0], &targets)) {
                        for (targets.items) |t| switch (t) {
                            .func => |target| if (target < self.built.funcs.items.len and !std.mem.containsAtLeastScalar(hir.FuncId, out.items, 1, target)) {
                                try out.append(self.arena, target);
                            },
                            // A host call with a callback contract
                            // instantiates its designated callback
                            // arguments: those targets are real callees of
                            // this body (docs/effects.md §13), so they
                            // belong in the call graph — otherwise a
                            // callback recursion misses the SCC `Diverge`
                            // seed. Only contracts `callBound` will honour
                            // are instantiated, so the graph matches the
                            // summaries it feeds.
                            .host => |hb| if (self.hosts.lookupEntry(hb)) |e| {
                                if (e.stilla_execution == .may_execute) {
                                    if (e.callbacks) |positions| for (positions) |pos| {
                                        if (pos < ops.len - 1) try self.collectCallableTarget(ops[@as(usize, pos) + 1], out);
                                    };
                                }
                            },
                        };
                    }
                }
            }
            if (node.op == drop_op) {
                const ops = pr.operands(id);
                if (ops.len > 0) {
                    var vids = std.ArrayListUnmanaged(meta.Type).empty;
                    defer vids.deinit(self.arena);
                    try self.collectTypeHooks(pr.node(ops[0]).ty, &vids, out);
                }
            }
            for (pr.operands(id)) |op| try work.append(self.arena, op);
            for (pr.regionsOf(id)) |r| try work.append(self.arena, pr.region(r).root);
        }
    }

    /// Record the function targets of a callable argument (a host
    /// contract's instantiated callback) so they become edges of this
    /// body's call graph — resolved through the same local narrowing as
    /// any other indirect value.
    fn collectCallableTarget(self: *Analysis, arg: hir.ExprId, out: *std.ArrayListUnmanaged(hir.FuncId)) Error!void {
        var targets = std.ArrayListUnmanaged(ResolvedTarget).empty;
        defer targets.deinit(self.arena);
        if (!try self.resolveTargets(arg, &targets)) return;
        for (targets.items) |t| switch (t) {
            .func => |target| if (target < self.built.funcs.items.len and !std.mem.containsAtLeastScalar(hir.FuncId, out.items, 1, target)) {
                try out.append(self.arena, target);
            },
            .host => {},
        };
    }

    /// Solve one SCC to its least fixpoint from `Bottom`, with the
    /// `Diverge` seed for a recursive component, then finalize.
    fn solveComponent(self: *Analysis, comp: []const hir.FuncId, adj: []const std.ArrayListUnmanaged(hir.FuncId)) Error!void {
        var recursive = comp.len > 1;
        if (!recursive) {
            for (adj[comp[0]].items) |t| {
                if (t == comp[0]) recursive = true;
            }
        }
        const seed: Summary = if (recursive) effects.may_diverge else effects.pure;
        const cid = self.comp_of[comp[0]];
        self.solving = cid;
        defer self.solving = null;
        for (comp) |f| self.cur[f] = seed;

        const next = try self.arena.alloc(Summary, comp.len);
        while (true) {
            // A round is a simultaneous (Jacobi) update: the memo is
            // cleared so every body summary is derived from the same
            // `cur` approximation, all `next` values are computed, and
            // only then is `cur` reassigned.
            @memset(self.memo, null);
            for (comp, 0..) |f, k| {
                const body = try self.recordBodySummary(self.built.funcs.items[f]);
                next[k] = try effects.join(self.arena, seed, body);
            }
            var changed = false;
            for (comp, 0..) |f, k| {
                if (!next[k].eql(self.cur[f])) {
                    self.cur[f] = next[k];
                    changed = true;
                }
            }
            if (!changed) break;
        }
        for (comp) |f| {
            self.summary[f] = self.cur[f];
            self.known[f] = true;
        }
    }

    fn recordBodySummary(self: *Analysis, rec: hir.FuncRecord) Error!Summary {
        // A module init also stores every slotted constant and runs the
        // constant initializers; neither lives in the synthetic empty
        // init body (hir_build `buildInitBody`), so its summary is
        // conservatively Top whenever the module has storage.
        if (rec.kind == .init and self.moduleHasStorage(rec.module)) return effects.top;
        return self.lambdaBodySummary(rec.root);
    }

    fn moduleHasStorage(self: *Analysis, module_index: u32) bool {
        if (module_index >= self.built.modules.items.len) return true;
        const range = self.built.modules.items[module_index].consts;
        for (self.built.consts.items[range.start..][0..range.len]) |c| {
            if (c.slot != null) return true;
        }
        return false;
    }

    // -----------------------------------------------------------------
    // `never_returns` must fact (docs/effects.md §10.1)
    // -----------------------------------------------------------------

    /// The function-level must fact `never_returns(f)` (docs/effects.md
    /// §10.1): `f` has no normal return path — its declared return type
    /// is `never`, or its body never normalizes. Solved as the **greatest
    /// fixpoint** over the call graph: `never returns` is a coinductive
    /// property, so `fn f() -> void { f() }` really never returns, and a
    /// least fixpoint seeded `false` would miss it. Iteration starts from
    /// "every function never returns" and decreases monotonically (the
    /// transfer is monotone), stabilizing within `#funcs + 1` rounds. An
    /// out-of-range id is `false`.
    pub fn neverReturns(self: *Analysis, fid: hir.FuncId) Error!bool {
        try self.ensureNeverComputed();
        if (fid >= self.never_returns.len) return false;
        return self.never_returns[fid];
    }

    /// The structural `never` predicate on an expression subtree:
    /// evaluating `id` never completes normally. A `never`-typed node
    /// returns no value (Core §13.2); a strictly-evaluated operand that
    /// never normalizes makes its parent never as well; an exhaustive
    /// branch never normalizes only when every arm does; a `call` never
    /// normalizes when every resolvable target does. Anything unproven is
    /// `false` — the predicate is a must fact (取不到即 false).
    ///
    /// Iterative post-order over the tree (no recursion: a deep `let`
    /// chain is bounded by the heap, not the stack), memoized in
    /// `never_memo` under one fixed `never_returns` approximation.
    pub fn exprNever(self: *Analysis, id: hir.ExprId) Error!bool {
        try self.ensureNeverComputed();
        return self.exprNeverTree(id);
    }

    fn ensureNeverComputed(self: *Analysis) Error!void {
        if (self.never_computed) return;
        try self.computeNeverReturns();
    }

    fn computeNeverReturns(self: *Analysis) Error!void {
        const n = self.built.funcs.items.len;
        @memset(self.never_returns, true);
        if (n == 0) {
            self.never_computed = true;
            return;
        }
        const next = try self.arena.alloc(bool, n);
        var rounds: usize = 0;
        while (rounds <= n) : (rounds += 1) {
            // One Jacobi round: every body is evaluated against the same
            // approximation (`never_returns` is untouched until the
            // simultaneous assignment below).
            @memset(self.never_memo, null);
            for (0..n) |i| {
                const rec = self.built.funcs.items[i];
                var v = isNeverType(rec.ret);
                if (!v) {
                    const regs = self.p().regionsOf(rec.root);
                    if (regs.len > 0) v = try self.exprNeverTree(self.p().region(regs[0]).root);
                }
                next[i] = v;
            }
            var changed = false;
            for (0..n) |i| {
                if (next[i] != self.never_returns[i]) {
                    self.never_returns[i] = next[i];
                    changed = true;
                }
            }
            if (!changed) break;
        }
        // The fact is final now; drop the round-local memo so the public
        // queries memoize against it.
        @memset(self.never_memo, null);
        self.never_computed = true;
    }

    const NeverVisit = struct { id: hir.ExprId, expand: bool };

    /// Memoized `exprNever` for `id`, filling the memo for its whole
    /// subtree (children before parents).
    fn exprNeverTree(self: *Analysis, root: hir.ExprId) Error!bool {
        const pr = self.p();
        if (root >= self.never_memo.len) return false;
        var stack = std.ArrayListUnmanaged(NeverVisit).empty;
        defer stack.deinit(self.arena);
        try stack.append(self.arena, .{ .id = root, .expand = false });
        while (stack.pop()) |it| {
            if (self.never_memo[it.id] != null) continue;
            if (it.expand) {
                self.never_memo[it.id] = try self.exprNeverOfNode(it.id);
                continue;
            }
            try stack.append(self.arena, .{ .id = it.id, .expand = true });
            for (pr.operands(it.id)) |op| if (op < self.never_memo.len) try stack.append(self.arena, .{ .id = op, .expand = false });
            for (pr.regionsOf(it.id)) |r| {
                const child = pr.region(r).root;
                if (child < self.never_memo.len) try stack.append(self.arena, .{ .id = child, .expand = false });
            }
        }
        return self.never_memo[root].?;
    }

    /// A node's memoized `exprNever`, `false` for a node appended after
    /// this analysis was built (no entry yet — a later round re-analyzes).
    fn neverMemoAt(self: *Analysis, id: hir.ExprId) bool {
        if (id >= self.never_memo.len) return false;
        return self.never_memo[id] orelse false;
    }

    fn exprNeverOfNode(self: *Analysis, id: hir.ExprId) Error!bool {
        const pr = self.p();
        const n = pr.node(id);
        if (isNeverType(n.ty)) return true;
        const name = hir.registry.get(n.op).name;
        // A λ value's creation runs no body: it is a normal value.
        if (std.mem.eql(u8, name, "lambda")) return false;
        const ops = pr.operands(id);
        const regs = pr.regionsOf(id);
        if (std.mem.eql(u8, name, "call")) {
            for (ops) |op| if (self.neverMemoAt(op)) return true;
            return self.callTargetsNever(id);
        }
        switch (hir.registry.get(n.op).policy) {
            // `if` / `and` / `or` / `match`: the head is strict, at most
            // one arm runs, so the node is never only when the head is
            // never or every arm independently never normalizes. (For
            // the short-circuit rows the constant arm always returns, so
            // this reduces to the head — sound and conservative.)
            .branch, .short_circuit, .match => {
                if (ops.len > 0 and self.neverMemoAt(ops[0])) return true;
                if (regs.len == 0) return false;
                for (regs) |r| if (!self.neverMemoAt(pr.region(r).root)) return false;
                return true;
            },
            // Every other op (including `let`) evaluates every operand
            // and region root eagerly, so any one never normalizing makes
            // the parent never normalizing.
            else => {
                for (ops) |op| if (self.neverMemoAt(op)) return true;
                for (regs) |r| if (self.neverMemoAt(pr.region(r).root)) return true;
                return false;
            },
        }
    }

    /// Whether every resolvable target of the call at `id` has the
    /// `never_returns` fact. An unresolved callee, an empty target set,
    /// or a target that may return is `false`.
    fn callTargetsNever(self: *Analysis, id: hir.ExprId) Error!bool {
        const pr = self.p();
        const ops = pr.operands(id);
        if (ops.len == 0) return false;
        // An inline λ callee has no function record; its body is the fact.
        if (pr.node(ops[0]).op == lambda_op) {
            const regs = pr.regionsOf(ops[0]);
            if (regs.len == 0) return false;
            return self.neverMemoAt(pr.region(regs[0]).root);
        }
        var targets = std.ArrayListUnmanaged(ResolvedTarget).empty;
        defer targets.deinit(self.arena);
        if (!(try self.resolveTargets(ops[0], &targets))) return false;
        if (targets.items.len == 0) return false;
        for (targets.items) |t| {
            const nr = switch (t) {
                .func => |fid| if (fid < self.never_returns.len) self.never_returns[fid] else false,
                .host => |hb| self.hostNeverReturns(hb),
            };
            if (!nr) return false;
        }
        return true;
    }

    fn hostNeverReturns(self: *Analysis, hb: hir.HostBindingId) bool {
        if (hb >= self.built.hosts.items.len) return false;
        return switch (self.built.hosts.items[hb].signature) {
            .function => |f| isNeverType(f.ret.*),
            else => false,
        };
    }

    /// The body summary of a λ/fn node: the body's `eval_effect`
    /// sequenced with the function's normal-exit cleanup (docs/effects.md
    /// §6.1, §11.2). The cleanup is the body's registered footprint —
    /// full-expression temporaries plus the scope-end destruction of the
    /// function's owned Unique parameters and body locals — or `Top`
    /// when unmodelled.
    pub fn lambdaBodySummary(self: *Analysis, root: hir.ExprId) Error!Summary {
        const pr = self.p();
        const rs = pr.regionsOf(root);
        if (rs.len == 0) return effects.top;
        const reg = pr.region(rs[0]);
        const body = try self.effectOf(reg.root);
        const cleanup: Summary = (try self.cleanupEffect(reg.root)) orelse effects.top;
        return effects.sequence(self.arena, body, cleanup);
    }

    // -----------------------------------------------------------------
    // Capability (Copy / Unique) resolution
    // -----------------------------------------------------------------

    /// The structural ownership class of a monomorphic HIR type, or null
    /// when it cannot be classified (callers treat null as Unique).
    pub fn capabilityOf(self: *Analysis, ty: meta.Type) Error!?meta.Ownership {
        if (ty.ownership()) |ow| return ow;
        if (ty == .named) {
            const n = ty.named;
            if (n.id < self.built.types.len) {
                switch (self.built.types[n.id]) {
                    .struct_ => |d| if (d.ownership) |ow| return ow,
                    .union_ => |d| if (d.ownership) |ow| return ow,
                    .opaque_ => return .unique,
                    .unknown => {},
                }
                if (self.config.graph) |g| {
                    if (self.declModule(g, n.id)) |info| {
                        if (moduleinfo.ownershipOf(moduleinfo.resolveOf(g), info, ty)) |ow| return ow;
                    }
                }
            }
        }
        return null;
    }

    fn declModule(self: *Analysis, g: *moduleinfo.ModuleGraph, type_id: meta.TypeId) ?*moduleinfo.ModuleInfo {
        if (type_id >= self.built.types.len) return null;
        const spec = switch (self.built.types[type_id]) {
            .struct_ => |d| d.module,
            .union_ => |d| d.module,
            .opaque_ => |d| d.module,
            .unknown => return null,
        };
        for (g.modules) |info| {
            if (std.mem.eql(u8, info.specifier, spec)) return info;
        }
        return null;
    }

    // -----------------------------------------------------------------
    // Operand uses (docs/effects.md §4)
    // -----------------------------------------------------------------

    /// Resolve one operand occurrence's use from the descriptor policy
    /// (never stored as a fourth "dynamic" variant).
    pub fn operandUseOf(self: *Analysis, id: hir.ExprId, index: usize) Error!effects.OperandUse {
        const pr = self.p();
        const d = hir.registry.get(pr.node(id).op);
        return switch (d.uses) {
            .none, .all_read => .read,
            .all_consume => .consume,
            .static_list => if (index < d.operand_uses.len) d.operand_uses[index] else .consume,
            .operand_capability => if (index < pr.operands(id).len)
                self.capabilityUse(pr.operands(id)[index])
            else
                .consume,
            .callee_params => if (index == 0) .read else self.callArgUse(id, index),
        };
    }

    fn capabilityUse(self: *Analysis, op: hir.ExprId) Error!effects.OperandUse {
        const pr = self.p();
        if (pr.viewOf(op) == .borrowed) return .borrow;
        const cap = try self.capabilityOf(pr.node(op).ty) orelse return .consume;
        return if (cap == .unique) .consume else .read;
    }

    fn callArgUse(self: *Analysis, call_id: hir.ExprId, index: usize) Error!effects.OperandUse {
        const pr = self.p();
        const ops = pr.operands(call_id);
        if (ops.len == 0 or index >= ops.len) return .consume;
        const arg = ops[index];
        if (pr.viewOf(arg) == .borrowed) return .borrow;
        const cty = pr.node(ops[0]).ty;
        if (cty == .function) {
            const params = cty.function.params;
            const pi = index - 1;
            if (pi < params.len) {
                switch (params[pi].mode) {
                    .borrow => return .borrow,
                    .move => return .consume,
                    .plain => {
                        const cap = try self.capabilityOf(params[pi].type_);
                        return if (cap != null and cap.? == .copy) .read else .consume;
                    },
                }
            }
        }
        // Unknown callee/signature: conservative.
        return .consume;
    }

    // -----------------------------------------------------------------
    // Cleanup gate (docs/effects.md §11, MVP cleanup-free path)
    // -----------------------------------------------------------------

    /// Prove `expr`'s evaluated subtree creates no temporary needing
    /// destruction: every executed node has a Copy type, every owned
    /// region binding is Copy, and no `drop` appears. λ bodies are
    /// deferred (their cleanup rides the call's `effect_bound`). Anything
    /// unproven returns false — the caller then adds `Top` cleanup.
    pub fn cleanupFree(self: *Analysis, id: hir.ExprId) Error!bool {
        var work = std.ArrayListUnmanaged(hir.ExprId).empty;
        defer work.deinit(self.arena);
        try work.append(self.arena, id);
        while (work.pop()) |cur| {
            const pr = self.p();
            const n = pr.node(cur);
            if (n.op == drop_op) return false;
            // A borrowed / destruction view is not a temporary owner: it
            // creates nothing to clean up. Requiring Copy on the value a
            // view points at would wrongly mark every drop-hook body
            // (which reads fields of a borrowed, Unique value) unclean.
            if (pr.viewOf(cur) == .owned) {
                const cap = try self.capabilityOf(n.ty) orelse return false;
                if (cap != .copy) return false;
            }
            const d = hir.registry.get(n.op);
            if (d.transfer == .lambda) continue; // value creation; body is deferred
            for (pr.operands(cur)) |op| try work.append(self.arena, op);
            for (pr.regionsOf(cur)) |r| {
                if (try self.regionOwnsUnique(r)) return false;
                try work.append(self.arena, pr.region(r).root);
            }
        }
        return true;
    }

    /// Any non-borrow region binding holds a Unique value, which is
    /// destroyed at scope end — so the subtree is **not** literally
    /// cleanup-free. The scope-end destruction itself is modelled by the
    /// registered `scope_end` tokens (docs/effects.md §11.2); this
    /// predicate is the literal `cleanupFree` gate, kept strict for β /
    /// speculatability / reorder, which require a subtree with no
    /// destruction at all.
    fn regionOwnsUnique(self: *Analysis, reg_id: hir.RegionId) Error!bool {
        const pr = self.p();
        for (pr.params(reg_id)) |bid| {
            const b = pr.binder(bid);
            if (b.mode == .borrow) continue;
            const cap = try self.capabilityOf(b.ty) orelse return true;
            if (cap != .copy) return true;
        }
        return false;
    }

    /// Ownership/lifetime gate (docs/effects.md §12.3): no borrowed or
    /// destruction view anywhere in the evaluated subtree, no `Borrow`/
    /// `Consume` operand use, and no full-expression boundary crossing.
    pub fn ownershipGate(self: *Analysis, id: hir.ExprId) Error!bool {
        const pr = self.p();
        const root_fe = pr.node(id).full_expr;
        var work = std.ArrayListUnmanaged(hir.ExprId).empty;
        defer work.deinit(self.arena);
        try work.append(self.arena, id);
        while (work.pop()) |cur| {
            const n = pr.node(cur);
            if (pr.viewOf(cur) != .owned) return false;
            if (n.full_expr != root_fe) return false;
            const d = hir.registry.get(n.op);
            if (d.transfer == .lambda) continue;
            const ops = pr.operands(cur);
            var i: usize = 0;
            while (i < ops.len) : (i += 1) {
                if (try self.operandUseOf(cur, i) != .read) return false;
            }
            // Recurse into operands, not only regions: a nested
            // `move`/`borrow`/lazy operand otherwise escapes the gate.
            for (ops) |op| try work.append(self.arena, op);
            for (pr.regionsOf(cur)) |r| try work.append(self.arena, pr.region(r).root);
        }
        return true;
    }

    // -----------------------------------------------------------------
    // Derived queries (docs/effects.md §10.1)
    // -----------------------------------------------------------------

    /// The node's *stored* `ready` summary, or null while pending. A
    /// query that reads null fails closed; it never derives on the fly.
    pub fn readySummary(self: *Analysis, id: hir.ExprId) ?Summary {
        const it = &self.p().effect_interner;
        const sid = self.p().effectOf(id).readyId() orelse return null;
        if (sid >= it.summaries.items.len) return null;
        return it.summary(sid);
    }

    /// `eval_effect(expr) ; cleanup_effect(expr)` (docs/effects.md §11.2).
    /// Null while the expression's effect is pending. The cleanup is the
    /// registered full-expression footprint when modelled, otherwise
    /// `Top` — never `Pure` for an unmodelled subtree.
    pub fn observedEffect(self: *Analysis, id: hir.ExprId) Error!?Summary {
        const e = self.readySummary(id) orelse return null;
        const cleanup: Summary = (try self.cleanupEffect(id)) orelse effects.top;
        const out = try effects.sequence(self.arena, e, cleanup);
        return out;
    }

    /// `cleanup_effect(expr)` (docs/effects.md §11.2): `drop_effect(T)`
    /// for every registered destruction whose origin is in `expr`'s
    /// evaluated subtree, folded in reverse creation order. Two kinds of
    /// token share the table: `full_expression` temporaries (origin =
    /// the value-producing node) and `scope_end` bindings (origin = the
    /// region root, scheduled at its outer-FE end). Returns null when
    /// the cleanup is **unmodelled** (the program never ran the builder
    /// cleanup pass, so an empty table is not a proof). Callers must
    /// treat null as `Top`. A registered destruction with an
    /// unclassifiable type widens to `Top` through `drop_effect(T)` and
    /// still fails closed.
    pub fn cleanupEffect(self: *Analysis, id: hir.ExprId) Error!?Summary {
        const pr = self.p();
        if (!pr.cleanup_modeled) return null;
        var in_subtree = std.AutoHashMapUnmanaged(hir.ExprId, void).empty;
        defer in_subtree.deinit(self.arena);
        var work = std.ArrayListUnmanaged(hir.ExprId).empty;
        defer work.deinit(self.arena);
        try work.append(self.arena, id);
        while (work.pop()) |cur| {
            try in_subtree.put(self.arena, cur, {});
            const n = pr.node(cur);
            if (hir.registry.get(n.op).transfer == .lambda) continue; // deferred to the call
            for (pr.operands(cur)) |op| try work.append(self.arena, op);
            for (pr.regionsOf(cur)) |r| try work.append(self.arena, pr.region(r).root);
        }
        // Token list is append-ordered by creation; walk it backwards so
        // destruction order (reverse creation) folds first-to-last.
        var acc: ?Summary = null;
        var i = pr.cleanup_tokens.items.len;
        while (i > 0) {
            i -= 1;
            const tk = pr.cleanup_tokens.items[i];
            if (!in_subtree.contains(tk.origin_expr)) continue;
            const drop = try self.dropEffectOf(tk.ty);
            acc = if (acc) |a| try effects.sequence(self.arena, a, drop) else drop;
        }
        return acc orelse effects.pure;
    }

    /// Whether `expr`'s cleanup is modelled and discardable (docs/effects.md
    /// §11.2): `discard_view(cleanup_effect) == Pure`. Used by the derived
    /// predicates that depend on the full-expression cleanup rather than
    /// on the stronger, literal cleanup-free proof.
    pub fn cleanupDiscardable(self: *Analysis, id: hir.ExprId) Error!bool {
        const ce = (try self.cleanupEffect(id)) orelse return false;
        return effects.isPure(try effects.discardView(self.arena, ce));
    }

    /// Whether destroying a value of `ty` is itself discardable — the
    /// scope-end destructor a dead-`let` rewrite would remove
    /// (docs/effects.md §11.2, [hir.md](hir.md) §6.4). Unmodelled cleanup
    /// fails closed.
    pub fn bindingCleanupDiscardable(self: *Analysis, ty: meta.Type) Error!bool {
        if (!self.p().cleanup_modeled) return false;
        const d = try self.dropEffectOf(ty);
        return effects.isPure(try effects.discardView(self.arena, d));
    }

    pub fn isTotal(self: *Analysis, id: hir.ExprId) bool {
        const s = self.readySummary(id) orelse return false;
        return effects.isTotal(s);
    }

    pub fn observableEffectFree(self: *Analysis, id: hir.ExprId) bool {
        const s = self.readySummary(id) orelse return false;
        return effects.isObservableEffectFree(s);
    }

    /// `total` + `observable_effect_free` + cleanup-safe (docs/effects.md
    /// §10.1, §11). The M2 selective-A-Normal-Form predicate
    /// (`can_float_as_tree`). Cleanup-safety is the modelled
    /// full-expression footprint (`cleanupDiscardable`), not the
    /// stronger literal `cleanupFree`.
    pub fn canFloatAsTree(self: *Analysis, id: hir.ExprId) Error!bool {
        const s = self.readySummary(id) orelse return false;
        if (!effects.isTotal(s)) return false;
        if (!effects.isObservableEffectFree(s)) return false;
        if (!try self.cleanupDiscardable(id)) return false;
        return self.ownershipGate(id);
    }

    /// `discardable` (docs/effects.md §10.1): total, no observable
    /// effect, `discard_view(observed_effect) == Pure` (which counts the
    /// expression's own cleanup and ignores `Q`), and the ownership gate.
    pub fn isDiscardable(self: *Analysis, id: hir.ExprId) Error!bool {
        const s = self.readySummary(id) orelse return false;
        if (!effects.isTotal(s)) return false;
        if (!effects.isObservableEffectFree(s)) return false;
        const observed = try self.observedEffect(id) orelse return false;
        if (!effects.isPure(try effects.discardView(self.arena, observed))) return false;
        return self.ownershipGate(id);
    }

    /// `duplicable` (docs/effects.md §10.1): discardable, Copy result,
    /// all operand uses `Read`, and no `Q`.
    pub fn isDuplicable(self: *Analysis, id: hir.ExprId) Error!bool {
        const s = self.readySummary(id) orelse return false;
        if (s.nondeterministic) return false;
        if (!try self.isDiscardable(id)) return false;
        const cap = try self.capabilityOf(self.p().node(id).ty) orelse return false;
        if (cap != .copy) return false;
        return self.ownershipGate(id);
    }

    /// The **semantic** SEG-safety predicate (docs/effects.md §12.3):
    /// Copy, total, no observable effect, no `Q`, cleanup-safe, recursive
    /// ownership/lifetime gate. Admission additionally needs encoding
    /// support (`isSegAdmissible`).
    pub fn isSegSafe(self: *Analysis, id: hir.ExprId) Error!bool {
        const s = self.readySummary(id) orelse return false;
        if (!effects.isTotal(s)) return false;
        if (!effects.isObservableEffectFree(s)) return false;
        if (s.nondeterministic) return false;
        const cap = try self.capabilityOf(self.p().node(id).ty) orelse return false;
        if (cap != .copy) return false;
        if (!try self.cleanupFree(id)) return false;
        return self.ownershipGate(id);
    }

    /// Whether the op carries a SEG encoding (hir.md §3.5 `seg`, §8.1).
    /// The v1 M2a island set is registered in the OpRegistry; admission
    /// also needs the semantic predicate (`isSegSafe`), so a `true` here
    /// is necessary but not sufficient (`isSegAdmissible`).
    pub fn hasSegEncoding(self: *Analysis, op: hir.OpId) bool {
        _ = self;
        return hir.registry.get(op).seg != null;
    }

    pub fn isSegAdmissible(self: *Analysis, id: hir.ExprId) Error!bool {
        if (!self.hasSegEncoding(self.p().node(id).op)) return false;
        return self.isSegSafe(id);
    }

    /// `isIntrinsicallySpeculatable` (docs/effects.md §10.5): the weak
    /// unary fact — total, no observable effect, no `Q`, plus the
    /// mandatory ownership gate and cleanup proof. Necessary but not
    /// sufficient; code motion must also consult `canMove`-style path
    /// context, which M1b does not expose because the FE/lifetime facts
    /// it would need are unmodelled. The ownership gate is what makes
    /// `move.effects == {}` insufficient on its own (§6.2 强约束).
    pub fn isIntrinsicallySpeculatable(self: *Analysis, id: hir.ExprId) Error!bool {
        const s = self.readySummary(id) orelse return false;
        if (!effects.isTotal(s)) return false;
        if (!effects.isObservableEffectFree(s)) return false;
        if (s.nondeterministic) return false;
        if (!try self.cleanupFree(id)) return false;
        return self.ownershipGate(id);
    }

    /// `canSwapOperands` (docs/effects.md §10.5): v1 limits the swap to
    /// *adjacent* eager operands of a `StrictLTR` parent. Both operands
    /// must be `ready`, lie in the parent's full expression, carry a
    /// cleanup proof and pass the ownership gate (operand uses `Read`,
    /// owned views — no nested `Consume`/`Borrow`), and be
    /// order-compatible under the declared resource registry (conflicts
    /// and trap crossings are rejected). Equal summaries alone never
    /// authorize a swap.
    pub fn canSwapOperands(self: *Analysis, parent: hir.ExprId, lhs_slot: u16, rhs_slot: u16) Error!bool {
        const pr = self.p();
        const d = hir.registry.get(pr.node(parent).op);
        if (d.policy != .strict_ltr) return false;
        const ops = pr.operands(parent);
        if (lhs_slot >= ops.len or rhs_slot >= ops.len) return false;
        if (lhs_slot == rhs_slot) return true;
        const lo: u16 = @min(lhs_slot, rhs_slot);
        const hi: u16 = @max(lhs_slot, rhs_slot);
        if (hi - lo != 1) return false;
        const a = ops[lo];
        const b = ops[hi];
        const a_s = self.readySummary(a) orelse return false;
        const b_s = self.readySummary(b) orelse return false;
        const parent_fe = pr.node(parent).full_expr;
        if (pr.node(a).full_expr != parent_fe) return false;
        if (pr.node(b).full_expr != parent_fe) return false;
        // How the *parent* consumes each slot: a `Consume`/`Borrow` slot
        // is unsafe to swap even when the operand's own subtree passes
        // the ownership gate.
        if (try self.operandUseOf(parent, lo) != .read) return false;
        if (try self.operandUseOf(parent, hi) != .read) return false;
        if (!try self.cleanupFree(a)) return false;
        if (!try self.cleanupFree(b)) return false;
        if (!try self.ownershipGate(a)) return false;
        if (!try self.ownershipGate(b)) return false;
        return effects.orderCompatible(a_s, b_s, self.config.resources);
    }

    /// `canMaterializeOperand` (docs/effects.md §12.1): the operand at
    /// `slot` of `parent` may be hoisted into a synthesized `let`
    /// initializer. Two derived obligations:
    ///
    /// - the operands before `slot` are deferred past it. `canFloatAsTree`
    ///   already covers each one's own evaluation and full-expression
    ///   cleanup (the ANF selector only reaches a slot whose predecessors
    ///   are floatable), but for a `Class.seq` parent each earlier operand
    ///   is a *discarded statement*: sliding its in-place destruction past
    ///   the hoisted operand is observable when its value is Unique-owned,
    ///   so those must be Copy.
    /// - the hoisted operand's destruction point must not move. Copy has no
    ///   destructor; a Unique value is admissible only when the parent
    ///   already transfers it (`Consume`) or discards it in place (a
    ///   `Class.seq` non-last operand), so the synthesized binder's scope-end
    ///   destruction coincides with the anonymous temporary's
    ///   full-expression one (docs/effects.md §11.2).
    ///
    /// The one op-shape fact is the sequence's operand discipline (the same
    /// kind of descriptor read `canSwapOperands` makes of `policy`);
    /// `operandUseOf` supplies the parent's use. Unknown capabilities fail
    /// closed.
    pub fn canMaterializeOperand(self: *Analysis, parent: hir.ExprId, slot: u32) Error!bool {
        const pr = self.p();
        const ops = pr.operands(parent);
        const k: usize = slot;
        if (k >= ops.len) return false;
        const is_seq = hir.registry.get(pr.node(parent).op).class == .seq;
        if (is_seq) {
            for (ops[0..k]) |op| {
                const cap = try self.capabilityOf(pr.node(op).ty) orelse return false;
                if (cap != .copy) return false;
            }
        }
        const cap = try self.capabilityOf(pr.node(ops[k]).ty) orelse return false;
        if (cap == .copy) return true;
        if (try self.operandUseOf(parent, k) == .consume) return true;
        return is_seq and k + 1 < ops.len;
    }

    /// Whether two value positions are order-compatible at all (the
    /// resource/trap input to `canSwapOperands`). Unknown (pending)
    /// facts conflict.
    pub fn orderCompatible(self: *Analysis, a: hir.ExprId, b: hir.ExprId) bool {
        const sa = self.readySummary(a) orelse return false;
        const sb = self.readySummary(b) orelse return false;
        return effects.orderCompatible(sa, sb, self.config.resources);
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
    try testing.expect(undeclared.accesses.all[@intFromEnum(effects.EffectMode.read)]);
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

test "hir_effects: a Copy result with hidden Unique cleanup is not discardable" {
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
    // The function returns a Copy value but binds a Unique local: its
    // normal-exit cleanup is unmodelled, so the summary is Top.
    try testing.expect((try an.functionSummary(funcId(&f, "app.inner").?)).eql(effects.top));
    // A call to it inherits that Top: not discardable, not floatable,
    // not SEG-safe, even though the result type is Copy.
    for (f.built.program.exprs.items, 0..) |e, i| {
        if (!std.mem.eql(u8, hir.registry.get(e.op).name, "call")) continue;
        const id: hir.ExprId = @intCast(i);
        const s = an.readySummary(id) orelse continue;
        if (!s.eql(effects.top)) continue;
        try testing.expect(!(try an.isDiscardable(id)));
        try testing.expect(!(try an.canFloatAsTree(id)));
        try testing.expect(!(try an.isSegSafe(id)));
        try testing.expect(!(try an.isIntrinsicallySpeculatable(id)));
        try testing.expect((try an.validate(testing.allocator)) == null);
        return;
    }
    return error.TestUnexpectedResult;
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
        const cap = (try an.capabilityOf(e.ty)) orelse .unique;
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
        const cap = (try an.capabilityOf(e.ty)) orelse .unique;
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
        const cap = (try an.capabilityOf(e.ty)) orelse .unique;
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
                try testing.expect(meta.Type.eql(pr.node(tk.origin_expr).ty, tk.ty));
                const name = hir.registry.get(pr.node(tk.origin_expr).op).name;
                try testing.expect(!std.mem.eql(u8, name, "local"));
                try testing.expect(!std.mem.eql(u8, name, "move"));
                try testing.expect(!std.mem.eql(u8, name, "drop"));
            },
            .scope_end => |se| {
                // The anchor is the region root; the token's type is the
                // destroyed binding's.
                try testing.expect(meta.Type.eql(pr.binder(se.binder).ty, tk.ty));
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
        const cap = (try an.capabilityOf(b.ty)) orelse .unique;
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
        const cap = (try an.capabilityOf(b.ty)) orelse .unique;
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
    const c0 = try built.program.addExpr(.{ .op = hir.opId("const").?, .ty = i32ty, .payload = .{ .const_value = .{ .int = 10 } } });
    const c1 = try built.program.addExpr(.{ .op = hir.opId("const").?, .ty = i32ty, .payload = .{ .const_value = .{ .int = 20 } } });
    const lm = try built.program.addExpr(.{ .op = hir.opId("list_make").?, .ty = list_ty, .operands = try built.program.addOperands(&.{ c0, c1 }) });
    const in_range = try built.program.addExpr(.{ .op = hir.opId("field_get").?, .ty = i32ty, .operands = try built.program.addOperands(&.{lm}), .payload = .{ .field = 1 } });
    const oob = try built.program.addExpr(.{ .op = hir.opId("field_get").?, .ty = i32ty, .operands = try built.program.addOperands(&.{lm}), .payload = .{ .field = 2 } });
    const not_ctor = try built.program.addExpr(.{ .op = hir.opId("field_get").?, .ty = i32ty, .operands = try built.program.addOperands(&.{c0}), .payload = .{ .field = 0 } });
    var an = try Analysis.init(a, &built, .{});
    // The statically-known `list_make` length proves the in-range read
    // cannot trap (the bounds proof the projection rule consumes).
    try testing.expect(effects.isPure(an.fieldGetOwn(in_range)));
    // No proof in either direction: the conservative `Top` stands.
    try testing.expect(an.fieldGetOwn(oob).may_trap);
    try testing.expect(an.fieldGetOwn(not_ctor).may_trap);
}
