//! Pass: if-conversion — the branchless select (optimizer.md, Pass 8.8).
//! In: a lowered `cfg.IrProgram` (after PRE, which simplifies the arms
//! by hoisting the redundant computations out of them). Out: the same
//! program, with every pure *select diamond* replaced by one `select`
//! op per joined phi (the LLIR image of a select is `copy cond_reg` +
//! `cmov` — the branchless alternative to the compare-and-branch plus
//! the two edge copies).
//!
//! Pattern:
//!
//!     B0: …; br %c, B1, B2
//!     B1: <pure, non-consuming instrs>; j B3     (or none — the values
//!     B2: <pure, non-consuming instrs>; j B3      come from a dominator)
//!     B3: %r = phi [%p, B1], [%q, B2]; …
//!
//! Rewrites to:
//!
//!     B0: …; <hoisted arm instrs>; %r' = select %c, %p, %q; j B3
//!     B3: …        (the phis removed, their uses forwarded to the
//!                   selects)
//!
//! The emptied arms — left with just their `j` — become unreachable and
//! are removed by the dead-block pass that follows in the driver
//! sequence; this pass maintains the predecessor sets itself (the
//! validator's forward-edge check runs between passes).
//!
//! Fires only when **all** hold:
//! - B1 ≠ B2, neither is B0 nor the join; each arm has B0 as its only
//!   predecessor, and the join's phis have exactly the [B1, B2]
//!   incomings.
//! - Every instruction in each arm is pure (`opInfo.pure()` — no
//!   effects, no traps) **and** non-consuming (`consumes == .none`):
//!   if-conversion may neither hoist a side effect onto a path that
//!   could skip it, nor a trap the branch would have avoided, nor a
//!   consumption (a `move`/`unpack` of a unique base is conditional
//!   destruction — hoisting it would double-drop the else path's
//!   cleanup). Dead pure instructions are hoisted too — they become
//!   dead in the cond block and are cleaned by dead-instruction
//!   elimination; only the arm's whole removal matters.
//! - Every phi at the join converts (the arms are deleted afterwards —
//!   a phi that cannot convert would strand).
//! - The selected values are scalar *Copy* types (int32/uint32/float32/
//!   byte/bool): `cmov` is a pattern move over the 32-bit scalar cells,
//!   not an ownership transfer. str/any/aggregate/unique joins stay
//!   branchy.
//!
//! Allocations use the program's backing allocator (the arena); the
//! pass frees nothing.

const std = @import("std");
const cfg = @import("stilla").cfg;

/// One converted join phi: the phi, its result, and the then/else
/// incoming values (from B1/B2 respectively).
const Convert = struct {
    phi: *cfg.Instr,
    result: *cfg.Value,
    then: *cfg.Value,
    els: *cfg.Value,
};

/// One emitted select: the phi result it replaces and the select's own
/// result value (used-forward by `cfg.rewriteUses`).
const Emitted = struct {
    phi_result: *cfg.Value,
    sel_value: *cfg.Value,
};

/// Rewrite every convertible select diamond in `program`.
pub fn ifConvert(program: *cfg.IrProgram, allocator: std.mem.Allocator) !void {
    for (program.funcs) |f| {
        try convertFunc(f, allocator);
    }
}

/// Convert `f`'s select diamonds. Each conversion rewrites the cond
/// block's instruction list and terminator — other blocks' lists are
/// never edited mid-scan, so iterating `f.blocks` while converting is
/// safe; a block whose shape changed underneath a later diamond simply
/// fails that diamond's arm check (conservative).
fn convertFunc(f: *cfg.IrFunc, allocator: std.mem.Allocator) !void {
    var changed = false;
    for (f.blocks) |b0| {
        if (b0.terminator != .br) continue;
        if (try convertDiamond(f, b0, allocator)) changed = true;
    }
    if (changed) try cfg.renumberValues(f, allocator);
}

/// True when every instruction of `b` may be hoisted into the cond
/// block: pure (no effects, no traps) and non-consuming.
fn hoistableArm(b: *cfg.BasicBlock) bool {
    for (b.instrs) |ins| {
        const info = cfg.opInfo(std.meta.activeTag(ins.op));
        if (!info.pure() or info.consumes != .none) return false;
    }
    return true;
}

/// Scalar *Copy* type — the `cmov` domain (32-bit pattern moves).
fn scalarCopy(t: cfg.Type) bool {
    return switch (t) {
        .primitive => |p| switch (p) {
            .int32, .uint32, .float32, .byte, .bool => true,
            else => false,
        },
        else => false,
    };
}

/// Try to convert the select diamond rooted at `b0`'s `br`. Returns
/// whether it converted.
fn convertDiamond(f: *cfg.IrFunc, b0: *cfg.BasicBlock, allocator: std.mem.Allocator) !bool {
    const br = b0.terminator.br;
    const b1 = br.then_;
    const b2 = br.else_;
    // The arms are distinct, neither is the cond block nor a self-loop.
    if (b1 == b2 or b1 == b0 or b2 == b0) return false;
    // Each arm has exactly one predecessor: the cond block.
    if (b1.preds.len != 1 or b1.preds[0] != b0) return false;
    if (b2.preds.len != 1 or b2.preds[0] != b0) return false;
    // Both arms fall through to the same join.
    const b3 = switch (b1.terminator) {
        .j => |t| t,
        else => return false,
    };
    if (b3 == b0 or b3 == b1 or b3 == b2) return false;
    if (switch (b2.terminator) {
        .j => |t| t == b3,
        else => false,
    } == false) return false;

    // Every phi at the join must be a two-incoming phi over the arms
    // with scalar Copy incoming values — collect the converts first, so
    // a non-convertible phi skips the whole diamond (the arms would be
    // deleted, stranding it).
    var converts = std.ArrayList(Convert).empty;
    defer converts.deinit(allocator);
    for (b3.instrs) |instr| {
        if (instr.op != .phi) break; // phis are the block head
        const phi = &instr.op.phi;
        if (phi.incoming.len != 2) return false;
        const inc0 = phi.incoming[0];
        const inc1 = phi.incoming[1];
        // One incoming from each arm — in either order.
        const then: *cfg.Value = if (inc0.pred == b1) inc0.value else if (inc1.pred == b1) inc1.value else return false;
        const els: *cfg.Value = if (inc0.pred == b2) inc0.value else if (inc1.pred == b2) inc1.value else return false;
        const r = instr.results[0];
        if (!scalarCopy(r.type_)) return false;
        if (then.ownership != .copy or els.ownership != .copy) return false;
        try converts.append(allocator, .{ .phi = instr, .result = r, .then = then, .els = els });
    }
    if (converts.items.len == 0) return false; // nothing to select

    // Every arm instruction must be hoistable (pure, non-consuming) —
    // a diamond with an impure arm stays branchy.
    if (!hoistableArm(b1) or !hoistableArm(b2)) return false;

    // Build the cond block's new instruction list: the original
    // instructions, the hoisted arm instructions, then one select per
    // converted phi. The selects read the hoisted results and the
    // dominator-defined incoming values.
    var out = std.ArrayList(*cfg.Instr).empty;
    defer out.deinit(allocator);
    for (b0.instrs) |ins| try out.append(allocator, ins);
    for (b1.instrs) |ins| try out.append(allocator, ins);
    for (b2.instrs) |ins| try out.append(allocator, ins);
    var emitted = std.ArrayList(Emitted).empty;
    defer emitted.deinit(allocator);
    for (converts.items) |c| {
        const sel = try allocator.create(cfg.Instr);
        const v = try allocator.create(cfg.Value);
        v.* = .{
            .id = 0, // renumberValues assigns the final id
            .span = c.phi.span,
            .type_ = c.result.type_,
            .ownership = .copy,
            .state = .owned,
            .origin = null,
            .def = sel,
        };
        sel.* = .{
            .span = c.phi.span,
            .results = try allocator.dupe(*cfg.Value, &.{v}),
            .op = .{ .select = .{ .cond = br.cond, .a = c.then, .b = c.els } },
            .synth = false,
        };
        try out.append(allocator, sel);
        try emitted.append(allocator, .{ .phi_result = c.result, .sel_value = v });
    }
    b0.instrs = try out.toOwnedSlice(allocator);
    // The arms' instructions now live in the cond block; empty the arms so
    // each Instr has exactly one containing block (the validator's defBlock
    // scan is first-match over f.blocks — a hoisted instruction left in an
    // arm whose block precedes the cond would be attributed to the arm and
    // rejected as not dominating its uses). The emptied arms keep only
    // their `j`, become unreachable, and are removed by dead-block
    // elimination, which follows in the driver sequence.
    b1.instrs = &.{};
    b2.instrs = &.{};

    // Forward every use of each phi result to its select, drop the phis
    // from the join, and redirect the cond block to fall through.
    for (emitted.items) |e| cfg.rewriteUses(f, e.phi_result, e.sel_value);
    b0.terminator = .{ .j = b3 };
    // The join's new in-edge: the validator's forward-edge check
    // requires the cond block listed among the join's predecessors.
    const preds = try allocator.alloc(*cfg.BasicBlock, b3.preds.len + 1);
    @memcpy(preds[0..b3.preds.len], b3.preds);
    preds[b3.preds.len] = b0;
    b3.preds = preds;
    // Remove the converted phis from the join.
    var kept = std.ArrayList(*cfg.Instr).empty;
    defer kept.deinit(allocator);
    for (b3.instrs) |ins| {
        var converted = false;
        for (converts.items) |c| {
            if (c.phi == ins) {
                converted = true;
                break;
            }
        }
        if (!converted) try kept.append(allocator, ins);
    }
    b3.instrs = try kept.toOwnedSlice(allocator);
    return true;
}
