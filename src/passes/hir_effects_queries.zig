//! Rewrite/SEG legality queries seam of the HIR effect analysis
//! (docs/effects.md §10.1/§12). The method bodies here were moved
//! verbatim out of the driver `passes/hir_effects.zig`, which keeps a
//! `pub const` alias per method so `an.<method>(...)` call syntax is
//! unchanged for every consumer; the docs live with each method body.

const std = @import("std");
const meta = @import("stilla").meta;
const hir = @import("stilla").hir;
const moduleinfo = @import("stilla").moduleinfo;
const effects = @import("stilla").effects;
const hir_effects = @import("hir_effects.zig");

const Analysis = hir_effects.Analysis;
const Error = hir_effects.Error;
const Summary = hir_effects.Summary;
const drop_op = hir_effects.drop_op;

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

pub fn declModule(self: *Analysis, g: *moduleinfo.ModuleGraph, type_id: meta.TypeId) ?*moduleinfo.ModuleInfo {
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

pub fn capabilityUse(self: *Analysis, op: hir.ExprId) Error!effects.OperandUse {
    const pr = self.p();
    if (pr.viewOf(op) == .borrowed) return .borrow;
    const cap = try self.capabilityOf(pr.typeOf(pr.node(op).ty)) orelse return .consume;
    return if (cap == .unique) .consume else .read;
}

pub fn callArgUse(self: *Analysis, call_id: hir.ExprId, index: usize) Error!effects.OperandUse {
    const pr = self.p();
    const ops = pr.operands(call_id);
    if (ops.len == 0 or index >= ops.len) return .consume;
    const arg = ops[index];
    if (pr.viewOf(arg) == .borrowed) return .borrow;
    const cty = pr.typeOf(pr.node(ops[0]).ty);
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
    var work = std.ArrayList(hir.ExprId).empty;
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
            const cap = try self.capabilityOf(pr.typeOf(n.ty)) orelse return false;
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
pub fn regionOwnsUnique(self: *Analysis, reg_id: hir.RegionId) Error!bool {
    const pr = self.p();
    for (pr.params(reg_id)) |bid| {
        const b = pr.binder(bid);
        if (b.mode == .borrow) continue;
        const cap = try self.capabilityOf(pr.typeOf(b.ty)) orelse return true;
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
    var work = std.ArrayList(hir.ExprId).empty;
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
    const cleanup: Summary = (try self.cleanupEffect(id)) orelse self.eng.top();
    const out = try self.eng.sequence(e, cleanup);
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
    var work = std.ArrayList(hir.ExprId).empty;
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
        const drop = try self.dropEffectOf(pr.typeOf(tk.ty));
        acc = if (acc) |a| try self.eng.sequence(a, drop) else drop;
    }
    return acc orelse effects.pure;
}

/// Whether `expr`'s cleanup is modelled and discardable (docs/effects.md
/// §11.2): `discard_view(cleanup_effect) == Pure`. Used by the derived
/// predicates that depend on the full-expression cleanup rather than
/// on the stronger, literal cleanup-free proof.
pub fn cleanupDiscardable(self: *Analysis, id: hir.ExprId) Error!bool {
    const ce = (try self.cleanupEffect(id)) orelse return false;
    return self.eng.isPure(try self.eng.discardView(ce));
}

/// Whether destroying a value of `ty` is itself discardable — the
/// scope-end destructor a dead-`let` rewrite would remove
/// (docs/effects.md §11.2, [hir.md](hir.md) §6.4). Unmodelled cleanup
/// fails closed.
pub fn bindingCleanupDiscardable(self: *Analysis, ty: meta.Type) Error!bool {
    if (!self.p().cleanup_modeled) return false;
    const d = try self.dropEffectOf(ty);
    return self.eng.isPure(try self.eng.discardView(d));
}

pub fn isTotal(self: *Analysis, id: hir.ExprId) bool {
    const s = self.readySummary(id) orelse return false;
    return self.eng.isTotal(s);
}

pub fn observableEffectFree(self: *Analysis, id: hir.ExprId) bool {
    const s = self.readySummary(id) orelse return false;
    return self.eng.isObservableEffectFree(s);
}

/// `total` + `observable_effect_free` + cleanup-safe (docs/effects.md
/// §10.1, §11). The selective A-Normal-Form predicate
/// (`can_float_as_tree`). Cleanup-safety is the modelled
/// full-expression footprint (`cleanupDiscardable`), not the
/// stronger literal `cleanupFree`.
pub fn canFloatAsTree(self: *Analysis, id: hir.ExprId) Error!bool {
    const s = self.readySummary(id) orelse return false;
    if (!self.eng.isTotal(s)) return false;
    if (!self.eng.isObservableEffectFree(s)) return false;
    if (!try self.cleanupDiscardable(id)) return false;
    return self.ownershipGate(id);
}

/// `discardable` (docs/effects.md §10.1): total, no observable
/// effect, `discard_view(observed_effect) == Pure` (which counts the
/// expression's own cleanup and ignores `Q`), and the ownership gate.
pub fn isDiscardable(self: *Analysis, id: hir.ExprId) Error!bool {
    const s = self.readySummary(id) orelse return false;
    if (!self.eng.isTotal(s)) return false;
    if (!self.eng.isObservableEffectFree(s)) return false;
    const observed = try self.observedEffect(id) orelse return false;
    if (!self.eng.isPure(try self.eng.discardView(observed))) return false;
    return self.ownershipGate(id);
}

/// `duplicable` (docs/effects.md §10.1): discardable, Copy result,
/// all operand uses `Read`, and no `Q`.
pub fn isDuplicable(self: *Analysis, id: hir.ExprId) Error!bool {
    const s = self.readySummary(id) orelse return false;
    if (s.nondeterministic) return false;
    if (!try self.isDiscardable(id)) return false;
    const cap = try self.capabilityOf(self.p().typeOf(self.p().node(id).ty)) orelse return false;
    if (cap != .copy) return false;
    return self.ownershipGate(id);
}

/// The **semantic** SEG-safety predicate (docs/effects.md §12.3):
/// Copy, total, no observable effect, no `Q`, cleanup-safe, recursive
/// ownership/lifetime gate. Admission additionally needs encoding
/// support (`isSegAdmissible`).
pub fn isSegSafe(self: *Analysis, id: hir.ExprId) Error!bool {
    const s = self.readySummary(id) orelse return false;
    if (!self.eng.isTotal(s)) return false;
    if (!self.eng.isObservableEffectFree(s)) return false;
    if (s.nondeterministic) return false;
    const cap = try self.capabilityOf(self.p().typeOf(self.p().node(id).ty)) orelse return false;
    if (cap != .copy) return false;
    if (!try self.cleanupFree(id)) return false;
    return self.ownershipGate(id);
}

/// Whether the op carries a SEG encoding (hir.md §3.5 `seg`, §8.1).
/// The v1 SEG island set is registered in the OpRegistry; admission
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
/// context, which the effect analysis does not expose because the FE/lifetime facts
/// it would need are unmodelled. The ownership gate is what makes
/// `move.effects == {}` insufficient on its own (§6.2 强约束).
pub fn isIntrinsicallySpeculatable(self: *Analysis, id: hir.ExprId) Error!bool {
    const s = self.readySummary(id) orelse return false;
    if (!self.eng.isTotal(s)) return false;
    if (!self.eng.isObservableEffectFree(s)) return false;
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
    return self.eng.orderCompatible(a_s, b_s);
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
            const cap = try self.capabilityOf(pr.typeOf(pr.node(op).ty)) orelse return false;
            if (cap != .copy) return false;
        }
    }
    const cap = try self.capabilityOf(pr.typeOf(pr.node(ops[k]).ty)) orelse return false;
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
    return self.eng.orderCompatible(sa, sb);
}
