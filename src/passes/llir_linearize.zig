//! Pass: LLIR linearization — the deferred-PC final stage of the
//! CFG-to-LLIR backend. In: the `Builder` after every record mutation
//! (allocation, lifecycle planning, budget, emission, fusion, spill
//! expansion) — each block's record list fully written with symbolic
//! targets: branch/jump/`jal` records carry placeholder offsets, and
//! the `switch_arms` rows hold their targets' symbolic `BlockId`s. Out:
//! the single global instruction array, the per-function
//! `FunctionDesc` code ranges (`code_start`/`code_end`/`entry_pc`) and
//! per-block `BlockDesc` rows, the `block_pcs` map, and every final
//! relative offset — branches, jumps, direct calls, and switch arms.
//! It is the only stage that computes or stores a PC; nothing before
//! it reads `block_pcs` or writes a final relative offset (Stilla LLIR
//! Specification §1, frontend.md "Backend: CFG → LLIR").
const std = @import("std");
const cfg = @import("stilla").cfg;
const llir = @import("stilla").llir;
const lower = @import("cfg_lower_llir.zig");

const Builder = lower.Builder;

/// Generate the linear form — the single global instruction
/// array plus every absolute-PC table — from the per-block record
/// lists. Runs last, after every record mutation (the peephole's
/// per-block compaction included), and is the only stage that
/// computes or stores a PC: the block lists are concatenated function
/// by function in FunctionId order, block by block in `ordered_blocks`
/// order, each block gets its start PC, the `FunctionDesc` code
/// ranges (`code_start`/`code_end`/`entry_pc`) and `BlockDesc` rows
/// are filled, and the branch targets are resolved — the `j`/`br`
/// fields to signed offsets from the branch's own `pc` (`j` a
/// 20-bit offset, `target = pc + signExtend20(offset)`;
/// compare-and-branch a signed 10-bit offset in `offs10`), the
/// `switch_arm` targets to signed offsets from the `switch`
/// instruction's own pc. Function ranges
/// are ordered, non-overlapping, and cover the whole instruction
/// space (any valid pc recovers a unique function).
///
/// The compare-and-branch reach is ±512; targets beyond it are
/// handled by the **long-branch expansion**, the safety net this
/// stage runs to convergence before
/// resolving: a far branch becomes an inverted branch that skips
/// over an inserted `j` (`b<inverted> a, b, +2` then `j target`),
/// so common programs (whose then-bodies sit near the branch) pay
/// nothing and only genuinely far targets expand. The records hold
/// no symbolic BlockId — a branch's target is a pure function of
/// the block's terminator and the emission form the budget tables
/// fixed (`branchTargetOf`), and the expansion marks the branch
/// with the `offs10 == 2` skip offset, so budget, emission, expansion,
/// and resolution all agree without ever storing a BlockId in a
/// 4-byte record.
pub fn run(bld: *Builder) error{OutOfMemory}!void {
    // Rounds: layout, then expand every out-of-reach branch. Each
    // branch expands at most once (the `offs10 == 2` marker), so the
    // loop converges after at most one round per expanded branch.
    while (true) {
        bld.expansion_rounds += 1;
        bld.instructions.clearRetainingCapacity();
        bld.block_descs.clearRetainingCapacity();
        var pc: u32 = 0;
        for (bld.ordered_funcs.items, 0..) |f, fi| {
            const r = bld.block_ranges.items[fi];
            const code_start = pc;
            var entry_pc: u32 = 0;
            for (r.start..r.start + r.len) |bi| {
                const blk = bld.ordered_blocks.items[bi];
                const start_pc = pc;
                try bld.block_pcs.put(bld.arena, blk, start_pc);
                if (blk == f.entry) entry_pc = start_pc;
                try bld.instructions.appendSlice(bld.arena, bld.block_records.items[bi].items);
                pc += @intCast(bld.block_records.items[bi].items.len);
                try bld.block_descs.append(bld.arena, .{ .start_pc = start_pc, .end_pc = pc });
            }
            const fd = &bld.func_descs.items[fi];
            fd.code_start = code_start;
            fd.code_end = pc;
            fd.entry_pc = entry_pc;
        }
        // The long-branch expansion scan: every block's terminator
        // is the compare-and-branch at `term` (or `jal`/`ret`/… —
        // never a branch). A branch whose carried target lies beyond
        // ±512 inverts (the integer reps, `beq`/`bne`, the immediate
        // families, `tbz`/`tbnz`) and gains a link-less `j` right after
        // it, or — for a NaN-ordered float `blt`/`ble` or an
        // immediate `blti`/`bltiu` — expands to
        // the three-record non-inverting trampoline. The inserted
        //
        // records shift the layout, so the round re-runs.
        var expanded = false;
        for (bld.ordered_blocks.items, 0..) |_, bi| {
            const term = bld.non_phi_counts.items[bi] + bld.edge_copy_counts.items[bi];
            const recs = &bld.block_records.items[bi];
            const rec = &recs.items[term];
            const d = llir.decode(rec.*) orelse continue;
            if (llir.formatOf(d.op) != .b) continue;
            if (d.offs10 == 2) continue; // expanded in an earlier round
            const branch_pc: u32 = bld.block_descs.items[bi].start_pc + @as(u32, @intCast(term));
            if (llir.fit10Signed(bld.pcOf(branchTargetOf(bld, @intCast(bi))), branch_pc) == null) {
                if (Builder.invertBranch(d.op)) |inv| {
                    // `b<inverted> lhs, rhs, +2` skips the inserted
                    // `j` (at pc + 1); the fall-through still
                    // lands on the next block. The integer ordering
                    // pairs (`blt`↔`ble`, `bltu`↔`bleu`) exchange
                    // their operands — `!(a<b) ≡ ble b,a`.
                    rec.* = llir.instrB(inv.op, if (inv.swap) d.b else d.a, if (inv.swap) d.a else d.b, 2);
                    try recs.insert(bld.arena, term + 1, llir.instrJ(0)); // placeholder: target by the fixup below
                } else {
                    // NaN-ordered float `blt`/`ble` (or the immediate
                    // `blti`/`bltiu`, which has no complement): the predicate
                    // cannot be inverted, so use the non-inverting
                    // trampoline `P lhs, rhs, +2; j +2; j
                    // far_target` — the predicate, when true,
                    // skips over the second `j` into the far
                    // jump; when false, the second `j` skips
                    // the far jump.
                    rec.* = llir.instrB(d.op, d.a, d.b, 2);
                    try recs.insert(bld.arena, term + 1, llir.instrJ(2)); // skip the far j (final)
                    try recs.insert(bld.arena, term + 2, llir.instrJ(0)); // placeholder: target by the fixup below
                }
                expanded = true;
            }
        }
        if (!expanded) break;
    }
    // Resolve the branch/jump targets to pc-relative offsets — the
    // only PC fixup in the pipeline, and it reads the final layout
    // (the last round's `instructions` copy). B-type branches use a
    // signed 10-bit offset; `jal` a signed 20-bit; an out-of-range
    // span fails via `operand_overflow`. A block's terminator is the
    // branch or a `j`; the trailing `j` of the two-record form
    // carries the `br` else target, and a long-branch-expanded
    // branch's inserted `j`(s) carry the branch's own target. The
    // records are located by their absolute
    // PCs — the block's terminator at `start_pc + term` — and
    // rewritten in the flat array, so the writes land in the image
    // `Builder.finish` snapshots.
    for (bld.ordered_blocks.items, 0..) |blk, bi| {
        const term = bld.non_phi_counts.items[bi] + bld.edge_copy_counts.items[bi];
        const branch_pc: u32 = bld.block_descs.items[bi].start_pc + @as(u32, @intCast(term));
        const td = llir.decode(bld.instructions.items[branch_pc]) orelse continue;
        switch (td.op) {
            .j => {
                // a `j` block terminator (the CFG jump, or a stage-7 edge
                // block's hand-off): the target routes through an edge
                // block when the edge has effects; for a synthetic edge
                // block the mapping is absent, so it stays the real
                // successor.
                const target = bld.pcOf(bld.targetForEdge(blk, blk.terminator.j));
                bld.instructions.items[branch_pc] = llir.instrJ(bld.fit20Signed(target, branch_pc));
            },
            else => if (llir.formatOf(td.op) == .b) {
                const blk_end = bld.block_descs.items[bi].end_pc;
                if (td.offs10 == 2) {
                    // Long-branch-expanded: the +2 skip is final.
                    // Integer expansions insert one `j` (pc + 1)
                    // carrying the branch's original target; the
                    // non-inverting trampoline (float `blt`/`ble`,
                    // immediate `blti`/`bltiu`) inserts a committed
                    // `j, +2` skip at pc + 1 and a far jump at
                    // pc + 2. A trailing `j` (the two-record form)
                    // carries the else target. A real branch
                    // whose target is exactly +2 (the float next-block
                    // form) has no +2-skip `jal` right after it, so the
                    // far/trail probes below see only its trailing
                    // `j`. Distinguish the two shapes by the
                    // committed +2-skip marker at pc + 1 — never by the
                    // operand rep, which would misclassify the integer
                    // `blti`/`bltiu` trampolines as inverted and
                    // rewrite their `+2` skip into a far jump.
                    const has_skip: bool = (branch_pc + 1) < blk_end and isSkipJInstr(bld.instructions.items[branch_pc + 1]);
                    const far: u32 = if (has_skip) branch_pc + 2 else branch_pc + 1;
                    const trail: u32 = if (has_skip) branch_pc + 3 else branch_pc + 2;
                    if (far < blk_end and isJInstr(bld.instructions.items[far])) {
                        const target = bld.pcOf(branchTargetOf(bld, @intCast(bi)));
                        bld.instructions.items[far] = llir.instrJ(bld.fit20Signed(target, far));
                    }
                    if (trail < blk_end and isJInstr(bld.instructions.items[trail])) {
                        const target = bld.pcOf(brElseTarget(bld, @intCast(bi)));
                        bld.instructions.items[trail] = llir.instrJ(bld.fit20Signed(target, trail));
                    }
                } else {
                    // Plain form: the branch carries `branchTargetOf`;
                    // a trailing `j` (the two-record form) the
                    // else target.
                    const target = bld.pcOf(branchTargetOf(bld, @intCast(bi)));
                    bld.instructions.items[branch_pc] = llir.instrB(td.op, td.a, td.b, bld.fit10Signed(target, branch_pc));
                    if (branch_pc + 1 < blk_end and isJInstr(bld.instructions.items[branch_pc + 1])) {
                        // the trailing j of the two-record form
                        const etarget = bld.pcOf(brElseTarget(bld, @intCast(bi)));
                        bld.instructions.items[branch_pc + 1] = llir.instrJ(bld.fit20Signed(etarget, branch_pc + 1));
                    }
                }
            },
        }
    }
    // Resolve the `jal ra` direct-call targets: the k-th direct call
    // instruction in a block emits the k-th `jal ra` record (calls
    // and their argument moves are never deleted or reordered by
    // fusion), so order-based matching is exact.
    try resolveJalCalls(bld);
    // Resolve the `switch` arm targets: each arm still holds its
    // target block's symbolic BlockId; replace it with the signed
    // offset from the `switch` instruction's own pc to the block's
    // pc — the decoded target `pc + offset`. Every switch owns its
    // descriptor, so each arm row
    // is written exactly once.
    for (bld.instructions.items, 0..) |instr, pc_usize| {
        const d = llir.decode(instr) orelse continue;
        if (d.op != .switch_) continue;
        const pc: u32 = @intCast(pc_usize);
        const sd = bld.switch_descs.items[d.imm16];
        for (sd.arms_start..sd.arms_start + sd.arms_len) |k| {
            const arm = &bld.switch_arms.items[k];
            const block = bld.ordered_blocks.items[@intCast(arm.target)];
            arm.target = @as(i32, @bitCast(bld.pcOf(block) -% pc));
        }
    }
}

/// Resolve every `jal ra` call record's signed 20-bit target: the
/// callee's `entry_pc` (filled by the final layout round), relative
/// to the call's own pc.
fn resolveJalCalls(bld: *Builder) error{OutOfMemory}!void {
    for (bld.ordered_funcs.items, 0..) |_, fi| {
        const r = bld.block_ranges.items[fi];
        for (r.start..r.start + r.len) |bi| {
            const blk = bld.ordered_blocks.items[bi];
            const blk_start = bld.block_descs.items[bi].start_pc;
            const blk_end = bld.block_descs.items[bi].end_pc;
            var k: u32 = 0;
            for (blk.instrs) |ins| {
                if (std.meta.activeTag(ins.op) != .call) continue;
                const call = ins.op.call;
                if (std.meta.activeTag(call.callee) != .direct) continue;
                // A cross-module call emits no `jal` record (the
                // symbolic import path ends in `jalr`), so it consumes
                // no entry in a block's direct-call sequence.
                if (bld.isCrossModuleName(call.callee.direct.name)) continue;
                var seen: u32 = 0;
                var pc = blk_start;
                while (pc < blk_end) : (pc += 1) {
                    const d = llir.decode(bld.instructions.items[pc]) orelse continue;
                    if (d.op == .jal and d.a == llir.ra_reg) {
                        if (seen == k) {
                            const fi2 = bld.func_name_ids.get(call.callee.direct.name) orelse unreachable;
                            const target = bld.func_descs.items[fi2].entry_pc;
                            bld.instructions.items[pc] = llir.instrU(.jal, llir.ra_reg, bld.fit20Signed(target, pc));
                            break;
                        }
                        seen += 1;
                    }
                }
                k += 1;
            }
        }
    }
}

/// Whether `instr` is a `j` — the unconditional intra-function jump
/// (Instruction Set §9.1).
fn isJInstr(instr: llir.Instr) bool {
    const d = llir.decode(instr) orelse return false;
    return d.op == .j;
}

/// Whether `instr` is the committed `j +2` skip — the
/// non-inverting long-branch trampoline's middle record (float
/// `blt`/`ble` and the complement-less `blti`/`bltiu`), inserted
/// with its `+2` offset final and never rewritten by the PC fixup.
fn isSkipJInstr(instr: llir.Instr) bool {
    const d = llir.decode(instr) orelse return false;
    return d.op == .j and d.imm20 == 2;
}

/// The target the compare-and-branch record of block `bi` carries
/// — recomputed from the emission form (never stored in the
/// record), routed through an edge block when the arm's edge has
/// effects (stage 7): the then-block in the two-record form and the
/// else-falls-through form, the else-block in the inverted form.
/// `terminatorRecordCount` made the identical decision on the same
/// conservative tables, so budget, emission, expansion, and
/// resolution agree.
fn branchTargetOf(bld: *const Builder, bi: u32) *const cfg.BasicBlock {
    const blk = bld.ordered_blocks.items[bi];
    const b = blk.terminator.br;
    if (bld.terminatorRecordCount(blk) == 1) {
        const next = bld.nextBlockOf(bi).?;
        return bld.targetForEdge(blk, if (next == b.else_) b.then_ else b.else_); // the inverted form carries else
    }
    return bld.targetForEdge(blk, b.then_);
}

/// The else target of block `bi`'s `br` — the trailing `j`'s
/// target in both the plain and the long-branch-expanded forms,
/// routed through an edge block when the else edge has effects.
fn brElseTarget(bld: *const Builder, bi: u32) *const cfg.BasicBlock {
    return bld.targetForEdge(bld.ordered_blocks.items[bi], bld.ordered_blocks.items[bi].terminator.br.else_);
}
