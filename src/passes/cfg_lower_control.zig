//! Pass: control-flow lowering — the `if`, `match`, and lambda expression
//! forms (Binding Power Table document) and short-circuit `and`/`or` (Core
//! §10, §11, §13; air.md §14.2–§14.3).
//! In: Lowerer + FuncState + AST control-flow nodes, module graph. Out:
//! CFG blocks, `br`/`switch`/`branch` terminators, and join phis.

const std = @import("std");
const cfg = @import("stilla").cfg;
const meta = @import("stilla").meta;
const moduleinfo = @import("stilla").moduleinfo;
const type_resolve = @import("type_resolve.zig");
const lower = @import("stilla").lower;
const cfg_lower_expr = @import("cfg_lower_expr.zig");
const cfg_lower_call = @import("cfg_lower_call.zig");
const cfg_lower_func = @import("cfg_lower_func.zig");
const cfg_lower_pattern = @import("cfg_lower_pattern.zig");
const cfg_lower_emit = @import("cfg_lower_emit.zig");
const cfg_lower_intrinsic = @import("cfg_lower_intrinsic.zig");

const Lowerer = lower.Lowerer;
const FuncState = lower.FuncState;
const LowerError = lower.LowerError;
const isMoveExpr = cfg_lower_expr.isMoveExpr;

/// An incoming (value, predecessor) pair for a join phi, in edge order.
pub const JoinIn = struct {
    v: ?*cfg.Value,
    /// The block that actually branches to the join (the one fs.cur
    /// points at when the branch is set); for a nested rhs/arm/body
    /// that is the inner join block, not the branch's entry block.
    b: *cfg.BasicBlock,
};

/// `a and b`: the right operand is evaluated only when `a` is true —
pub fn trapUnreachableJoin(self: *Lowerer, fs: *FuncState, join: *cfg.BasicBlock) LowerError!void {
    fs.cur = join;
    try cfg_lower_emit.setTerminator(self, fs, .{ .trap = {} });
}

/// Create the join phi from the (value, predecessor) pairs. Values
/// are in edge order; a null value (a `trap`-terminated predecessor)
/// contributes no input (air.md §4.3). A void join produces no phi.
///
/// Ownership (air.md §6.3-6.4): an unique value listed as a phi input
/// is *not* destroyed at the end of its producing block — the phi
/// result becomes the single owner. The inputs are therefore marked
/// consumed here (their cleanup tokens disarmed), so the full-expression
/// `dropCreatedRange` and the branch-end scope drops skip them, and only
/// the phi result (the join-scope owner) receives a scope-end drop
/// unless ownership transfers (e.g. `ret` of the phi result).
///
/// Join typing (Core §13.2, air.md §4.4): the phi's type is the *join
/// type* of the incoming values — identical types join to themselves,
/// a mix coercible to `any` joins as `any` — and the `T → any` coercion
/// is materialized on each predecessor edge (`any_pack_copy` for a
/// Copy source, `any_pack_move` for an unique source) so the phi
/// is homogeneous and ownership stays explicit.
pub fn makeJoinPhi(
    self: *Lowerer,
    fs: *FuncState,
    join: *cfg.BasicBlock,
    span: meta.Span,
    incoming: []const JoinIn,
) LowerError!?*cfg.Value {
    std.debug.assert(fs.cur == join);
    // Order the inputs by predecessor block id. The join's in-edges are
    // materialized in block order during finalization (air.md §3, §4.3),
    // and the inputs' real predecessors are the blocks that *actually*
    // branch to the join — for a nested rhs/arm/body these are inner
    // join blocks created after the outer branch blocks (e.g. `a and (b
    // and c)` branches to the outer join from the inner `b and c` join),
    // so the natural call-site order does not match the in-edge order.
    // A null value (a trapped predecessor) is skipped below and never
    // appears in either list.
    var sorted = std.ArrayList(JoinIn).empty;
    try sorted.appendSlice(self.arena, incoming);
    std.mem.sort(JoinIn, sorted.items, {}, struct {
        fn lt(_: void, a: JoinIn, b: JoinIn) bool {
            return a.b.id < b.b.id;
        }
    }.lt);
    // The join type: unify the non-null incoming types exactly as phase 2
    // does (never contributes nothing, equal types join to themselves,
    // anything else joins as `any`).
    var join_type: ?meta.Type = null;
    for (sorted.items) |inc| {
        const v = inc.v orelse continue;
        join_type = if (join_type) |jt| unifyType(jt, v.type_) else v.type_;
    }
    const jt = join_type orelse meta.Type{ .primitive = .void };
    if (cfg_lower_emit.isVoid(jt)) return cfg_lower_expr.emitVoid(self, fs, span);
    // Materialize the `T → any` coercion on each predecessor edge whose
    // incoming type differs from the join type (air.md §4.4). The packed
    // value replaces the incoming in the phi; an unique source is moved
    // in (consumed, token disarmed) on its own edge.
    var packed_v = try self.arena.alloc(?*cfg.Value, sorted.items.len);
    for (sorted.items, 0..) |inc, i| {
        const v = inc.v orelse {
            packed_v[i] = null;
            continue;
        };
        if (meta.Type.eql(v.type_, jt)) {
            packed_v[i] = v;
            continue;
        }
        const edge = inc.b;
        // A void branch value is a def-less phantom (emitVoid) — a real
        // `const void` is materialized on the edge so it can be packed.
        const src = if (cfg_lower_emit.isVoid(v.type_))
            (try cfg_lower_emit.emitInto(self, fs, edge, span, .{ .const_ = .void }, .{ .primitive = .void })).?
        else
            v;
        if (src.ownership == .unique) {
            const p = (try cfg_lower_emit.emitInto(self, fs, edge, span, .{ .any_pack_move = src }, jt)).?;
            cfg_lower_emit.markConsumed(self, fs, src);
            try cfg_lower_emit.cleanupDisableInto(self, fs, edge, span, src);
            packed_v[i] = p;
        } else {
            packed_v[i] = (try cfg_lower_emit.emitInto(self, fs, edge, span, .{ .any_pack_copy = src }, jt)).?;
        }
    }
    const phi = (try cfg_lower_emit.newPhi(self, fs, span, jt)).?;
    const builder = fs.phi_lists.get(phi.def.?) orelse unreachable;
    for (sorted.items, 0..) |inc, i| {
        const v = packed_v[i] orelse continue;
        cfg_lower_emit.markConsumed(self, fs, v);
        // A phi input with a cleanup token transfers ownership at the
        // join on every completing edge: disarm the token here — on a
        // path where the value was already consumed the token is already
        // disarmed, so this is idempotent.
        try cfg_lower_emit.cleanupDisable(self, fs, span, v);
        try builder.append(self.arena, .{ .value = v, .pred = inc.b });
    }
    return phi;
}

/// The join type of two branch values (Core §13.2, mirroring phase 2's
/// `unify`): `never` contributes nothing; equal types join to themselves;
/// a mixed pair joins as the top type `any`.
fn unifyType(a: meta.Type, b: meta.Type) meta.Type {
    if (a == .primitive and a.primitive == .never) return b;
    if (b == .primitive and b.primitive == .never) return a;
    if (meta.Type.eql(a, b)) return a;
    return meta.Type{ .primitive = .any };
}
