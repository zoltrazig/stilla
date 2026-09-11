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
//! - **Cleanup** (docs/effects.md §11) is the explicitly permitted MVP
//!   path: an expression is cleanup-free only when *every* executed node
//!   in its subtree has a Copy type, no owned Unique region binding
//!   exists, and no `drop` appears. `drop_effect(T)` is deliberately
//!   minimal (Copy → `{}`, anything else → `Top`); precise destructor
//!   summaries are deferred (docs/effects.md §14 再后 1). Unmodelled
//!   cleanup contributes `Top` and therefore blocks deletion, floating,
//!   duplication, and SEG admission — a Copy *result* alone never
//!   suffices. Full-expression token registration (`CleanupFootprint`)
//!   is not populated by the current builder, so empty registries are
//!   treated as unmodelled, not as proof.
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
const cfg = @import("stilla").cfg;
const hir = @import("stilla").hir;
const moduleinfo = @import("stilla").moduleinfo;
const effects = @import("stilla").effects;

pub const Summary = effects.Summary;
pub const Error = std.mem.Allocator.Error;

const lambda_op = hir.opId("lambda").?;
const fn_ref_op = hir.opId("fn_ref").?;
const drop_op = hir.opId("drop").?;

/// Optional external facts. M1b does not wire the embedding host ABI
/// (docs/effects.md §13) — an empty `hosts` table makes every host call
/// `Top`, and tests supply an analysis-local registry.
pub const Config = struct {
    hosts: effects.HostEffects = .{},
    resources: effects.ResourceRegistry = .{},
    /// The module graph, used only to resolve the ownership class of
    /// generic named type instantiations. Without it, such a type is
    /// conservatively Unique.
    graph: ?*moduleinfo.ModuleGraph = null,
};

const FnState = union(enum) {
    pending,
    visiting,
    ready: Summary,
};

pub const Analysis = struct {
    arena: std.mem.Allocator,
    built: *hir.BuiltProgram,
    config: Config,
    /// Per-node memo of the transfer result (analysis scratch, not the
    /// annotation; `validate` clears it to force an independent
    /// re-derivation).
    memo: []?Summary,
    fn_state: []FnState,

    pub fn init(arena: std.mem.Allocator, built: *hir.BuiltProgram, config: Config) Error!Analysis {
        const memo = try arena.alloc(?Summary, built.program.exprs.items.len);
        @memset(memo, null);
        const fn_state = try arena.alloc(FnState, built.funcs.items.len);
        for (fn_state) |*s| s.* = .pending;
        return .{ .arena = arena, .built = built, .config = config, .memo = memo, .fn_state = fn_state };
    }

    fn p(self: *Analysis) *hir.Program {
        return &self.built.program;
    }

    // -----------------------------------------------------------------
    // Annotation driver
    // -----------------------------------------------------------------

    /// Compute every function summary, then annotate every reachable
    /// node (function bodies and module-constant initializers) with its
    /// interned `ready` summary. Idempotent.
    pub fn analyze(self: *Analysis) Error!void {
        for (0..self.built.funcs.items.len) |fid| {
            _ = try self.functionSummary(@intCast(fid));
        }
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
        // per-node memo *first*, then reset the function-summary states
        // and recompute the summaries. Clearing the memo afterwards (or
        // not at all) would let `functionSummary` read stale per-node
        // facts, making the check compare an annotation against itself.
        @memset(self.memo, null);
        for (self.fn_state) |*s| s.* = .pending;
        for (0..self.built.funcs.items.len) |fid| {
            _ = try self.functionSummary(@intCast(fid));
        }
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
                    acc = try effects.sequence(self.arena, acc, try self.effectBound(ops[0]));
                }
                return acc;
            },
            .drop_effect => {
                var acc = d.own_effect;
                const ops = pr.operands(id);
                if (ops.len > 0) {
                    const cap = try self.capabilityOf(pr.node(ops[0]).ty);
                    acc = try effects.sequence(self.arena, acc, effects.dropEffect(cap));
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
    /// effect-free (`cfg.opInfo`). Any other base type is not a valid
    /// `field_get` (the lowering rejects it), so it is conservatively
    /// `Top` rather than assumed pure.
    fn fieldGetOwn(self: *Analysis, id: hir.ExprId) Summary {
        const ops = self.p().operands(id);
        if (ops.len == 0) return effects.top;
        return switch (self.p().node(ops[0]).ty) {
            .named, .tuple => effects.pure,
            else => effects.top,
        };
    }

    /// The effect of *calling* the value `callee` evaluates to
    /// (docs/effects.md §6.1 `effect_bound`), distinct from `effects(callee)`.
    pub fn effectBound(self: *Analysis, callee: hir.ExprId) Error!Summary {
        const n = self.p().node(callee);
        if (n.op == fn_ref_op) {
            return switch (n.payload) {
                .func => |fr| switch (fr) {
                    .func => |fid| self.functionSummary(fid),
                    .host => |hb| self.config.hosts.lookup(hb) orelse effects.top,
                },
                else => effects.top,
            };
        }
        if (n.op == lambda_op) return self.lambdaBodySummary(callee);
        // Indirect call: v1 is Top (docs/effects.md §9.1).
        return effects.top;
    }

    // -----------------------------------------------------------------
    // Function summaries
    // -----------------------------------------------------------------

    pub fn functionSummary(self: *Analysis, fid: hir.FuncId) Error!Summary {
        if (fid >= self.built.funcs.items.len) return effects.top;
        switch (self.fn_state[fid]) {
            .ready => |s| return s,
            // A recursive dependency: conservative Top, no fixpoint in M1b
            // (docs/effects.md §8.2 is M2b). Top propagates to callers.
            .visiting => return effects.top,
            .pending => {},
        }
        self.fn_state[fid] = .visiting;
        const rec = self.built.funcs.items[fid];
        const s = try self.recordBodySummary(rec);
        self.fn_state[fid] = .{ .ready = s };
        return s;
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

    /// The body summary of a λ/fn node: the body's `eval_effect`
    /// sequenced with the function's normal-exit cleanup (docs/effects.md
    /// §6.1). Owned Unique parameters/locals or an unprovable subtree
    /// make the cleanup `Top`.
    pub fn lambdaBodySummary(self: *Analysis, root: hir.ExprId) Error!Summary {
        const pr = self.p();
        const rs = pr.regionsOf(root);
        if (rs.len == 0) return effects.top;
        const reg = pr.region(rs[0]);
        const body = try self.effectOf(reg.root);
        const cleanup: Summary = if (try self.regionOwnsUnique(rs[0]) or !try self.cleanupFree(reg.root))
            effects.top
        else
            effects.pure;
        return effects.sequence(self.arena, body, cleanup);
    }

    // -----------------------------------------------------------------
    // Capability (Copy / Unique) resolution
    // -----------------------------------------------------------------

    /// The structural ownership class of a monomorphic HIR type, or null
    /// when it cannot be classified (callers treat null as Unique).
    pub fn capabilityOf(self: *Analysis, ty: cfg.Type) Error!?cfg.Ownership {
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

    fn declModule(self: *Analysis, g: *moduleinfo.ModuleGraph, type_id: cfg.TypeId) ?*moduleinfo.ModuleInfo {
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
            const cap = try self.capabilityOf(n.ty) orelse return false;
            if (cap != .copy) return false;
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
    /// destroyed at scope end (Static Semantics Destruction) — its
    /// destruction plan is not modelled here.
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
    /// Null while the expression's effect is pending.
    pub fn observedEffect(self: *Analysis, id: hir.ExprId) Error!?Summary {
        const e = self.readySummary(id) orelse return null;
        const cleanup: Summary = if (try self.cleanupFree(id)) effects.pure else effects.top;
        const out = try effects.sequence(self.arena, e, cleanup);
        return out;
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
    /// (`can_float_as_tree`).
    pub fn canFloatAsTree(self: *Analysis, id: hir.ExprId) Error!bool {
        const s = self.readySummary(id) orelse return false;
        if (!effects.isTotal(s)) return false;
        if (!effects.isObservableEffectFree(s)) return false;
        if (!try self.cleanupFree(id)) return false;
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

test "hir_effects: recursion is conservatively Top and propagates" {
    var f = try build("app", &.{.{
        "app",
        \\fn loop(n: int32) -> int32 { loop(n) }
        \\fn callit(n: int32) -> int32 { loop(n) }
    }});
    defer f.deinit();
    var an = try Analysis.init(f.arena.allocator(), f.built, .{ .graph = f.graph });
    try an.analyze();
    try testing.expect((try an.functionSummary(funcId(&f, "app.loop").?)).eql(effects.top));
    try testing.expect((try an.functionSummary(funcId(&f, "app.callit").?)).eql(effects.top));
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
    try testing.expect((try an.functionSummary(shout)).eql(effects.top));
    try testing.expect((try an.validate(testing.allocator)) == null);

    // Declare every host binding pure: the host call (and the intrinsic
    // wrapper behind `builtin.str`) becomes pure.
    const entries = try f.arena.allocator().alloc(effects.HostEffects.Entry, f.built.hosts.items.len);
    for (f.built.hosts.items, 0..) |_, i| {
        entries[i] = .{ .host = @intCast(i), .summary = effects.pure };
    }
    var an2 = try Analysis.init(f.arena.allocator(), f.built, .{
        .graph = f.graph,
        .hosts = .{ .entries = entries },
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
        entries[i] = .{ .host = @intCast(i), .summary = write_effects };
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
        entries[i] = .{ .host = @intCast(i), .summary = q };
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
        entries[i] = .{ .host = @intCast(i), .summary = effects.may_trap };
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
        entries[i] = .{ .host = @intCast(i), .summary = write };
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
        entries[i] = .{ .host = @intCast(i), .summary = write };
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
