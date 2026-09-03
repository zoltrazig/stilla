//! Pass: CFG → LLIR budgeting — per-block record sizing. In: the
//! `Builder` after slot allocation and lifecycle planning (value slots
//! and the trailing release records fixed; the edge-copy lists
//! resolvable). Out: the per-block `non_phi_counts`/
//! `edge_copy_counts`/`block_edge_starts` reservations, the
//! conservative `starts_cons`/`block_lens_cons` tables, and the
//! pre-sized block-local record lists that every emission stage fills
//! exactly. This is a block-local size only: no PC is assigned, and
//! const+op fusion later compacts a block's own list without affecting
//! any other. The record-count queries here (`recordCount`,
//! `mainRecordCount`, `callArgMoveCount`) are the shared contract every
//! stage that walks `blk.instrs` with the block-local record index —
//! emission and the fusion peephole — advances by, so sized and
//! emitted records agree by construction (Stilla LLIR Specification
//! §1).

const std = @import("std");
const cfg = @import("stilla").cfg;
const llir = @import("stilla").llir;
const lower = @import("cfg_lower_llir.zig");
const lifecycle = @import("cfg_lower_lifecycle.zig");
const edges = @import("cfg_lower_llir_edges.zig");
const typed = @import("cfg_lower_typed.zig");

const Builder = lower.Builder;

/// Size each block's record list — one record per non-phi
/// instruction (the n-ary forms stay atomic: one record + a
/// descriptor), the edge copies for its outgoing edges, and
/// the terminator record(s). The edge-copy count is
/// computed through the same `edges.edgeCopyList` the emit walk uses,
/// so sized and emitted records agree by construction.
pub fn run(bld: *Builder) error{OutOfMemory}!void {
    // Pre-computation, in three decision-free passes so the
    // tables later stages read are complete before anything consults
    // them: per-block non-phi counts + the edge-copy start positions
    // (dead-slot cutoff for `edges.cycleStagingSlotForType`, which the
    // edge-copy walk below may call), then the per-block edge-copy
    // counts + the conservative start/length tables (every `br` at
    // two records — the trailing-j reach check reads these, and the
    // final distances only shrink).
    if (bld.block_edge_starts.items.len < bld.ordered_blocks.items.len) {
        try bld.block_edge_starts.ensureTotalCapacity(bld.arena, bld.ordered_blocks.items.len);
        try bld.non_phi_counts.ensureTotalCapacity(bld.arena, bld.ordered_blocks.items.len);
        try bld.edge_copy_counts.ensureTotalCapacity(bld.arena, bld.ordered_blocks.items.len);
        try bld.starts_cons.ensureTotalCapacity(bld.arena, bld.ordered_blocks.items.len);
        try bld.block_lens_cons.ensureTotalCapacity(bld.arena, bld.ordered_blocks.items.len);
        var pos: u32 = 0; // edge-copy start accumulator (terminators at the fixed br = 2 count)
        for (bld.ordered_blocks.items) |blk| {
            var n: u32 = 0;
            for (blk.instrs) |ins| {
                if (std.meta.activeTag(ins.op) == .phi) continue;
                n += try recordCount(bld, blk, ins); // argument moves
            }
            bld.non_phi_counts.appendAssumeCapacity(n);
            bld.block_edge_starts.appendAssumeCapacity(pos + n);
            pos += n + brTermCons(blk); // the terminator record(s) reserved in the record list
        }
        var pos_cons: u32 = 0;
        for (bld.ordered_blocks.items) |blk| {
            var e: u32 = 0;
            if (bld.isEdgeBlock(blk)) {
                // Stage-7 edge block: one edge's phi copies then kills.
                const edge = bld.edge_block_srcs.get(blk).?;
                e += try edges.edgeCopyCount(bld, edge.pred, edge.succ);
                e += @intCast(lifecycle.edgeKills(bld, edge.pred, edge.succ).len);
            } else switch (blk.terminator) {
                // Ordinary blocks reserve no edge effects — every
                // effect-bearing edge lives in an edge block (stage 7).
                .tailcall => e += try edges.tailcallOverhead(bld, blk),
                else => {}, // j / br / switch / ret / trap
            }
            bld.edge_copy_counts.appendAssumeCapacity(e);
            const n = bld.non_phi_counts.items[bld.block_ids.get(blk).?];
            const len = n + e + brTermCons(blk);
            bld.starts_cons.appendAssumeCapacity(pos_cons);
            bld.block_lens_cons.appendAssumeCapacity(len);
            pos_cons += len;
        }
    }
    for (bld.ordered_blocks.items) |blk| {
        const bi = bld.block_ids.get(blk).?;
        const n = bld.non_phi_counts.items[bi];
        const e = bld.edge_copy_counts.items[bi];
        var recs = std.ArrayList(llir.Instr).empty;
        try recs.appendNTimes(bld.arena, std.mem.zeroes(llir.Instr), n + e + terminatorRecordCount(bld, blk));
        try bld.block_records.append(bld.arena, recs);
    }
}

/// The conservative terminator record count of a block for the
/// pre-computation tables: one per terminator, `br` fixed at two —
/// the trailing-j decision (which may drop a `br` to one record)
/// must not feed the tables it reads.
fn brTermCons(blk: *const cfg.BasicBlock) u32 {
    return if (std.meta.activeTag(blk.terminator) == .br) 2 else 1;
}

/// The number of LLIR records one CFG instruction occupies: 1 plus
/// its call-argument moves, plus one more for an integer
/// `le`/`ge` whose `not`(gt/lt) synthesis emits a second record,
/// plus the lifecycle pass's trailing releases after a final use.
/// Every stage that walks `blk.instrs` with the block-local record
/// index — emission, the budget sizing, the fusion peephole — advances
/// by this count so the stages agree on record placement.
pub fn recordCount(bld: *Builder, blk: *const cfg.BasicBlock, ins: *const cfg.Instr) error{OutOfMemory}!u32 {
    var n: u32 = try mainRecordCount(bld, blk, ins);
    n += @intCast(lifecycle.trailingOf(bld, ins).len);
    return n;
}

/// The instruction's own record count without lifecycle trailing:
/// the main record plus the composite expansions (`slot_*`
/// preparation, the C-Type comparison's `copy dst, cond`, the call's
/// generic `take`, the select pair). Cleanup
/// token ops produce nothing in v1.
pub fn mainRecordCount(bld: *Builder, blk: *const cfg.BasicBlock, ins: *const cfg.Instr) error{OutOfMemory}!u32 {
    switch (std.meta.activeTag(ins.op)) {
        .cleanup_arm, .cleanup_disarm, .cleanup_drop => return 0, // v1: elided
        else => {},
    }
    var n: u32 = 1 + (try callArgMoveCount(bld, blk, ins));
    // A cross-module call is `module_ref` + `load_member` + `jalr`
    // (two records beyond the direct `jal`), and a cross-module
    // `fn_ref` is `module_ref` + `load_member` (one record beyond the
    // local form) — the same import path the emitter writes.
    switch (ins.op) {
        .call => |c| if (c.callee == .direct and bld.isCrossModuleName(c.callee.direct.name)) {
            n += 2;
        },
        .fn_ref => |name| if (bld.isCrossModuleName(name)) {
            n += 1;
        },
        else => {},
    }
    // A `u64` constant lowers to a move-wide sequence
    // (1–4 records), not a single `const` record.
    if (isMoveWideConst(bld, ins)) {
        const plan = u64ConstPlan(@bitCast(ins.op.const_.int));
        n += plan.len - 1;
    }
    // A C-Type comparison (implicit cond) emits the comparison plus
    // `copy dst, cond` (2 records). A non-void call emits
    // `take dst, F(L+3+O-A)` after the `jal` (1 extra record) unless
    // the allocator coalesced the result onto the alias (Step 8).
    if (ctypeCmp(ins)) n += 1;
    switch (ins.op) {
        .le, .ge => |bin| {
            if (Builder.isInteger(bin.a.type_)) n += 1;
        },
        else => {},
    }
    // The typed integer arithmetic emits exactly one record (the
    // opcode carries the rep and self-canonicalizes — Instruction Set
    // §4); no canonicalization records exist in v10.
    if (std.meta.activeTag(ins.op) == .call and bld.callNeedsTake(blk, ins)) n += 1;
    // A select is two records: `copy cond_reg, %cond` plus `cmov`.
    if (std.meta.activeTag(ins.op) == .select) n += 1;
    return n;
}

/// The function containing `blk` (the `fi` whose `block_ranges` row covers
/// the block's global BlockId).
fn funcOf(bld: *const Builder, blk: *const cfg.BasicBlock) *const cfg.IrFunc {
    return bld.ordered_funcs.items[bld.funcIndexOfBlock(blk)];
}

/// True for comparisons, which all lower to C-Type and therefore
/// emit the extra `copy dst, cond` record.
fn ctypeCmp(ins: *const cfg.Instr) bool {
    const bin = switch (ins.op) {
        .eq, .ne, .lt, .le, .gt, .ge => |b| b,
        else => return false,
    };
    _ = bin;
    return true;
}

/// The number of argument-move records a call emits (0 for any
/// other instruction) — the block-local record-position offset the
/// per-instruction emit stages advance past.
pub fn callArgMoveCount(bld: *Builder, blk: *const cfg.BasicBlock, ins: *const cfg.Instr) error{OutOfMemory}!u32 {
    if (std.meta.activeTag(ins.op) != .call) return 0;
    return @intCast((try bld.callArgMoves(blk, ins)).len);
}

/// The number of LLIR records a CFG terminator lowers to:
/// one for every terminator, plus one more for a `br` — its image
/// is a compare-and-branch followed by the unconditional `j` that
/// carries the else-target. A `br` drops the
/// trailing `j` when one of its targets is the next block in the
/// layout: the else target then falls through (branch to then,
/// unchanged polarity), or — when the then body is the next block
/// and the else target sits within the compare-and-branch's ±127
/// reach — the condition inverts (blt↔ble, bltu↔bleu, beq↔bne;
/// `bne cond, zero` ↔ `beq cond, zero`) and the branch targets else
/// with the then body falling through. The reach check reads the
/// conservative `starts_cons`/`block_lens_cons` tables (every `br`
/// at two records — final distances only shrink), never the mutable
/// counts, so budget, emission, and the post-emission passes
/// (fusion, `compactNoopOwnership`) all agree.
pub fn terminatorRecordCount(bld: *const Builder, blk: *const cfg.BasicBlock) u32 {
    switch (blk.terminator) {
        .br => |b| {
            const bi = bld.block_ids.get(blk).?;
            const next = bld.nextBlockOf(bi) orelse return 2;
            if (next == b.else_) return 1; // else falls through
            if (next == b.then_) {
                // Inverted form: the branch's offs10 must cover
                // else, and the predicate must be invertible — a
                // float `blt`/`ble` is NaN-ordered and never
                // inverted (it stays the two-record form).
                if (Builder.fusedBranchOperands(b.cond)) |f| {
                    // The bit-test forms invert trivially; the
                    // register/immediate forms need an invertible
                    // predicate (a float `blt`/`ble` is not).
                    if (std.meta.activeTag(f) != .bit) {
                        const branch_op = switch (f) {
                            .reg => |r| r.op,
                            .imm => |i| i.op,
                            .bit => |t| t.op,
                        };
                        if (Builder.invertBranch(branch_op) == null) return 2;
                    }
                }
                // The else target may sit behind the current block (a
                // loop back edge) — offs10 is a signed offset, so the
                // distance is computed in a signed domain.
                const dist: i64 = @as(i64, bld.starts_cons.items[bld.block_ids.get(b.else_).?]) -
                    (@as(i64, bld.starts_cons.items[bi]) + @as(i64, bld.block_lens_cons.items[bi])) + 1;
                return if (dist >= -512 and dist <= 512) 1 else 2;
            }
            return 2;
        },
        else => return 1,
    }
}

/// The deterministic move-wide sequence materializing a `u64`
/// constant: the single
/// `movwzN`/`movwnN` starter whose subsequent non-default lanes
/// are fewest — a `movwz` starter defaults the other lanes to 0, a
/// `movwn` starter to 0xffff — ties choosing the smaller `N` — then
/// the `movwkN` fixes for the remaining lanes in 0→3 order. 1–4
/// records, a pure function of the bit pattern (no cross-block or
/// cross-constant optimization), so the budget (via
/// `mainRecordCount`) and `emitInterned` always agree on the
/// count.
pub const MoveWidePlan = struct {
    init_op: llir.Opcode,
    init_imm: u16,
    /// The `movwkN` fixes, in lane 0→3 emission order; null lanes
    /// already match the starter's write.
    wks: [4]?struct { n: u2, imm: u16 },
    /// Total records: 1 + the non-null `wks`.
    len: u32,
};

/// The lane value of `bits` at move-wide suffix `n`.
pub fn u64Lane(bits: u64, n: u2) u16 {
    return @truncate(bits >> llir.movwLaneShift(n));
}

/// The `movw*N` opcode at suffix `n` for one of the three move-wide
/// bases (`movwn0`/`movwz0`/`movwk0`) — the twelve opcodes are
/// contiguous `0xb2–0xbd`.
pub fn movwOp(base: llir.Opcode, n: u2) llir.Opcode {
    return @enumFromInt(@intFromEnum(base) + n);
}

pub fn u64ConstPlan(bits: u64) MoveWidePlan {
    var best_cost: u32 = 4;
    var best_op: llir.Opcode = .movwz0;
    var best_imm: u16 = 0;
    var best_n: u2 = 0;
    var best_default: u16 = 0;
    // Strict `<` keeps the earliest (smallest `N`, `movwz` before
    // `movwn` within one `N`) of the tied starters.
    for (0..4) |n0_raw| {
        const n0: u2 = @intCast(n0_raw);
        // The starter's lane-`n0` write: a `movwz` zero-extends the
        // imm into the lane, a `movwn` writes its complement
        // (`~H`) — so the `movwn` imm is the
        // complement of the target lane value.
        const lane_n0 = u64Lane(bits, n0);
        for ([_]struct { base: llir.Opcode, default: u16 }{
            .{ .base = .movwz0, .default = 0 },
            .{ .base = .movwn0, .default = 0xffff },
        }) |starter| {
            var cost: u32 = 0;
            for (0..4) |m_raw| {
                const m: u2 = @intCast(m_raw);
                if (m != n0 and u64Lane(bits, m) != starter.default) cost += 1;
            }
            if (cost < best_cost) {
                best_cost = cost;
                best_op = movwOp(starter.base, n0);
                best_imm = if (starter.base == .movwz0) lane_n0 else ~lane_n0;
                best_n = n0;
                best_default = starter.default;
            }
        }
    }
    var plan: MoveWidePlan = .{ .init_op = best_op, .init_imm = best_imm, .wks = .{ null, null, null, null }, .len = 1 };
    for (0..4) |m_raw| {
        const m: u2 = @intCast(m_raw);
        if (m == best_n) continue; // the starter already wrote this lane
        if (u64Lane(bits, m) == best_default) continue; // matches the starter's default
        plan.wks[m] = .{ .n = m, .imm = u64Lane(bits, m) };
        plan.len += 1;
    }
    return plan;
}

/// Whether a `const_` instruction lowers to a move-wide
/// sequence instead of a `const` record — the `u64` constants only
/// (i64/f64 keep the typed `const` path; no reverse type inference
/// for the pattern-only move-wide family).
pub fn isMoveWideConst(bld: *Builder, ins: *const cfg.Instr) bool {
    _ = bld;
    if (ins.results.len == 0) return false;
    // Guard the union: a `const_` can carry any type (an empty-list
    // const is `.list`, a folded string const `.str`, …) — only the
    // primitive `u64` type takes the move-wide path.
    if (ins.results[0].type_ != .primitive) return false;
    if (ins.results[0].type_.primitive != .uint64) return false;
    return switch (ins.op) {
        .const_ => |cv| switch (cv) {
            .int => true,
            else => false, // defensive: a non-int uint64 payload keeps the const path
        },
        else => false,
    };
}
