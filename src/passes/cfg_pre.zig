//! Pass: partial redundancy elimination (optimizer.md, Pass 8.1). In: a lowered
//! `cfg.IrProgram` (after constant folding and common subexpression
//! elimination). Out: the same program, with a computation that is
//! available on some — but not all — incoming edges of a join rewritten to
//! a phi at the join, inserting the computation on the edges that lacked
//! it.
//!
//! A computation in a block with several predecessors is *partially
//! redundant* when an identical computation already ran on some incoming
//! edges. PRE replaces the computation with a phi of the per-edge values:
//! on each edge where an identical computation ran, the phi takes that
//! result; on every other edge, a fresh copy of the computation is
//! inserted at the end of the predecessor, just before its terminator.
//! When *no* predecessor has the computation it is left alone (fully
//! redundant and fully unavailable computations are CSE's and dead-code
//! work, not PRE's).
//!
//! Candidates are the pure, deterministic, *non-trapping* ops: the
//! comparisons (`eq`/`ne`/`lt`/`le`/`gt`/`ge`), the total unary ops
//! (`not_`, `neg`, `abs`, `clz`, `popcount`, `type_is`), the total
//! wrapping arithmetic (`add`/`sub`/`mul`/`min`/`max` — integer forms
//! wrap modulo 2³², Runtime §7.2), the shifts (count masked to its low
//! 5 bits) and bitwise ops, `num_cast` (casts never trap, Runtime
//! §7.2), and the float forms of `div`/`rem` (IEEE: `x/0` is ±inf,
//! `x%0` is NaN — total). The *integer* forms of `div`/`rem` trap on a
//! zero divisor (and the 64-bit division-overflow case), so they stay
//! excluded: PRE moves a computation onto paths that previously skipped
//! it, and a trapping operation would change observable behavior.
//! Operands must match positionally (no commutativity), mirroring CSE.
//!
//! `num_cast` is matched with one extra condition: `cfg.identical`
//! compares only the operand, but a cast's *target type* lives on its
//! result value — two casts of the same operand to different types are
//! different computations, so availability additionally requires result
//! type equality. (The other candidates cannot hit this: their opcode
//! plus operand values fix the result type.)
//!
//! The hoist is sound because the candidate's operands are required to be
//! defined in a *strict dominator* of the join (or be parameters): they
//! are available at the join's head and on every predecessor, so the
//! inserted copies and the phi are well-formed, and the value's def stays
//! in a block that dominates every use. Only Copy results are
//! hoisted; reusing an unique value across several edges would change the
//! destruction schedule (air.md §6.4).
//!
//! The join's computation is deleted and a phi is inserted at the block
//! head with the *same* result value, so the value's identity (and every
//! dominated use) is unchanged; the number of instructions in the join
//! block is unchanged (one phi replaces one instruction). Values are
//! renumbered per function in text order afterwards so the added values
//! keep the round-trip contract (air.md §13). Allocations use the program's
//! backing allocator (the arena); the pass frees nothing.

const std = @import("std");
const cfg = @import("stilla").cfg;
const meta = @import("stilla").meta;

/// Eliminate partially redundant computations across join points.
pub fn pre(program: *cfg.IrProgram, allocator: std.mem.Allocator) !void {
    for (program.funcs) |f| {
        try preFunc(f, allocator);
    }
}

/// Rewrite every partially redundant computation in `f` into a join phi,
/// then renumber the function's values in text order.
fn preFunc(f: *cfg.IrFunc, allocator: std.mem.Allocator) !void {
    const dom = try dominators(f, allocator);
    defer {
        for (dom) |d| allocator.free(d);
        allocator.free(dom);
    }
    for (f.blocks) |b| {
        if (b.preds.len == 0) continue;
        const candidates = try candidatesOf(f, b, dom, allocator);
        for (candidates) |cand| {
            try eliminate(b, cand, allocator);
        }
    }
    try cfg.renumberValues(f, allocator);
}

/// Dominators as a bit matrix `dom[i][j]` = "block j dominates block i",
/// computed by the standard iterative fixpoint over predecessors.
/// Sized by the largest block id, not the block count: if dead-block
/// elimination removed blocks without renumbering (air.md §13 — ids are
/// not part of the text form), `f.blocks.len` under-counts live ids.
fn dominators(f: *cfg.IrFunc, allocator: std.mem.Allocator) ![][]bool {
    var max_id: usize = 0;
    for (f.blocks) |b| max_id = @max(max_id, b.id);
    const n = max_id + 1;
    const dom = try allocator.alloc([]bool, n);
    errdefer allocator.free(dom);
    for (dom) |*d| d.* = try allocator.alloc(bool, n);
    errdefer for (dom) |d| allocator.free(d);
    for (dom) |d| @memset(d, true);
    @memset(dom[f.entry.id], false);
    dom[f.entry.id][f.entry.id] = true;

    const scratch = try allocator.alloc(bool, n);
    defer allocator.free(scratch);
    var changed = true;
    while (changed) {
        changed = false;
        for (f.blocks) |b| {
            if (b == f.entry) continue;
            @memset(scratch, true);
            for (b.preds) |p| {
                const pd = dom[p.id];
                for (0..n) |i| scratch[i] = scratch[i] and pd[i];
            }
            scratch[b.id] = true;
            const d = dom[b.id];
            for (0..n) |i| {
                if (d[i] != scratch[i]) {
                    d[i] = scratch[i];
                    changed = true;
                }
            }
        }
    }
    return dom;
}

/// The hoistable computations of `b`: pure, non-trapping, Copy, with
/// operands available at the block head. Snapshot: the pass rewrites
/// `b.instrs` in place while iterating.
fn candidatesOf(
    f: *cfg.IrFunc,
    b: *cfg.BasicBlock,
    dom: [][]bool,
    allocator: std.mem.Allocator,
) ![]*cfg.Instr {
    var out = std.ArrayList(*cfg.Instr).empty;
    for (b.instrs) |instr| {
        if (instr.results.len == 0) continue;
        if (instr.results[0].ownership != .copy) continue;
        if (!isCandidate(instr)) continue;
        if (!operandsDominate(f, b, instr, dom)) continue;
        try out.append(allocator, instr);
    }
    return try out.toOwnedSlice(allocator);
}

/// True when `instr`'s operands are available at `b`'s head: each operand
/// is a parameter or is defined in a strict dominator of `b`. Operands
/// defined in `b` itself are excluded — nothing defined in a block is
/// available before its first instruction.
fn operandsDominate(
    f: *cfg.IrFunc,
    b: *cfg.BasicBlock,
    instr: *const cfg.Instr,
    dom: [][]bool,
) bool {
    var ops: [2]*cfg.Value = undefined;
    const n = operandsOf(instr, &ops);
    for (ops[0..n]) |v| {
        const d = v.def orelse continue;
        const db = defBlock(f, d) orelse continue;
        if (db == b) return false;
        if (!dom[b.id][db.id]) return false;
    }
    return true;
}

/// The operand values of a candidate instruction, at most two, in operand
/// position; returns the count.
fn operandsOf(instr: *const cfg.Instr, out: *[2]*cfg.Value) usize {
    return switch (instr.op) {
        // binary: both operands, in position
        .eq,
        .ne,
        .lt,
        .le,
        .gt,
        .ge,
        .add,
        .sub,
        .mul,
        .div,
        .rem,
        .min,
        .max,
        .shl,
        .shr,
        .bitand,
        .bitor,
        .bitxor,
        => |x| blk: {
            out[0] = x.a;
            out[1] = x.b;
            break :blk 2;
        },
        // unary: the single operand
        .not_, .neg, .abs, .clz, .popcount, .num_cast => |x| blk: {
            out[0] = x;
            break :blk 1;
        },
        .type_is => |x| blk: {
            out[0] = x.value;
            break :blk 1;
        },
        else => 0,
    };
}

/// The block containing `instr`, found by scan (CFGs are small and this
/// avoids a stale map after the pass inserts instructions).
fn defBlock(f: *const cfg.IrFunc, instr: *const cfg.Instr) ?*cfg.BasicBlock {
    for (f.blocks) |b| {
        for (b.instrs) |i| {
            if (i == instr) return b;
        }
    }
    return null;
}

/// Hoistable ops: pure, deterministic, and non-trapping (see the header).
/// `div`/`rem` are candidates only in their float forms — the integer
/// forms trap on a zero divisor (Runtime §7.2); the operand's primitive
/// kind picks the form, and a non-numeric operand (unreachable from the
/// checker) is treated as trapping.
fn isCandidate(instr: *const cfg.Instr) bool {
    return switch (instr.op) {
        .eq,
        .ne,
        .lt,
        .le,
        .gt,
        .ge,
        .not_,
        .type_is,
        .neg,
        .abs,
        .clz,
        .popcount,
        .num_cast,
        .add,
        .sub,
        .mul,
        .min,
        .max,
        .shl,
        .shr,
        .bitand,
        .bitor,
        .bitxor,
        => true,
        .div, .rem => isFloatBin(instr),
        else => false,
    };
}

/// True when `instr` is a float-typed `div`/`rem`: the IEEE forms are
/// total (`x/0` is ±inf, `x%0` is NaN, Runtime §7.2), while the integer
/// forms trap. A float-typed result is the discriminator (the result
/// type is the operand type).
fn isFloatBin(instr: *const cfg.Instr) bool {
    if (instr.results.len == 0) return false;
    return switch (instr.results[0].type_) {
        .primitive => |k| k == .float32 or k == .float64,
        else => false,
    };
}

/// Structural match of a predecessor instruction against the candidate:
/// `cfg.identical` (same opcode, same operands in position) plus the
/// `num_cast` result-type equality the identical-check cannot see (its
/// payload is only the operand; the target type lives on the result).
fn sameComputation(pi: *const cfg.Instr, cand: *const cfg.Instr) bool {
    if (!cfg.identical(pi.op, cand.op)) return false;
    if (cand.op == .num_cast or pi.op == .num_cast) {
        if (pi.results.len == 0 or cand.results.len == 0) return false;
        if (!meta.Type.eql(pi.results[0].type_, cand.results[0].type_)) return false;
    }
    return true;
}

/// Rewrite `cand` in `b` into a phi at the block head. `cand` is left
/// untouched when no predecessor computes it (no redundancy to remove).
fn eliminate(
    b: *cfg.BasicBlock,
    cand: *cfg.Instr,
    allocator: std.mem.Allocator,
) !void {
    // Availability per predecessor, in `b.preds` order (air.md §4.3). The
    // scan excludes `cand` itself so a self-loop counts as unavailable
    // unless a separate identical computation exists.
    const available = try allocator.alloc(?*cfg.Value, b.preds.len);
    var any = false;
    for (b.preds, 0..) |p, i| {
        var found: ?*cfg.Value = null;
        for (p.instrs) |pi| {
            if (pi == cand) continue;
            if (pi.results.len == 0) continue;
            if (sameComputation(pi, cand)) {
                found = pi.results[0];
                break;
            }
        }
        available[i] = found;
        if (found != null) any = true;
    }
    if (!any) return;

    // Incoming values: reuse a predecessor's computation where it ran,
    // insert a fresh one (speculatively — candidates never trap) at the
    // end of every other predecessor.
    const incoming = try allocator.alloc(cfg.PhiIn, b.preds.len);
    for (b.preds, 0..) |p, i| {
        const value = available[i] orelse (try insertAtEnd(p, cand, allocator)).results[0];
        incoming[i] = .{ .value = value, .pred = p };
    }

    // The phi takes over `cand`'s result value, so every dominated use
    // keeps its def; the join block keeps its instruction count (one phi
    // in, one computation out).
    const phi = try allocator.create(cfg.Instr);
    const one = try allocator.alloc(*cfg.Value, 1);
    one[0] = cand.results[0];
    phi.* = .{ .span = cand.span, .results = one, .op = .{ .phi = .{ .incoming = incoming } } };
    cand.results[0].def = phi;

    const new_instrs = try allocator.alloc(*cfg.Instr, b.instrs.len);
    var cand_index: usize = 0;
    while (b.instrs[cand_index] != cand) cand_index += 1;
    new_instrs[0] = phi;
    var dst: usize = 1;
    for (b.instrs, 0..) |old, i| {
        if (i == cand_index) continue;
        new_instrs[dst] = old;
        dst += 1;
    }
    b.instrs = new_instrs;
}

/// Append a copy of `cand`'s computation at the end of `p`, just before its
/// terminator, and return it. The predecessor slice is regrown (arena).
fn insertAtEnd(p: *cfg.BasicBlock, cand: *const cfg.Instr, allocator: std.mem.Allocator) !*cfg.Instr {
    const ninstr = try allocator.create(cfg.Instr);
    const nval = try allocator.create(cfg.Value);
    const one = try allocator.alloc(*cfg.Value, 1);
    one[0] = nval;
    ninstr.* = .{ .span = cand.span, .results = one, .op = cand.op };
    nval.* = .{
        .id = 0, // placeholder; renumber fixes it in text order
        .span = cand.span,
        .type_ = cand.results[0].type_,
        .ownership = cand.results[0].ownership,
        .state = .owned,
        .origin = null,
        .def = ninstr,
    };
    const old = p.instrs;
    const grown = try allocator.alloc(*cfg.Instr, old.len + 1);
    @memcpy(grown[0..old.len], old);
    grown[old.len] = ninstr;
    p.instrs = grown;
    return ninstr;
}
