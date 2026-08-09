//! Pass: CFG → LLIR edge planning — phi elimination and tailcall
//! preparation. In: the `Builder` after slot allocation, lifecycle
//! planning, and budgeting (value slots fixed; the per-block
//! `non_phi_counts`/`edge_copy_counts` reservations in place). Out: the
//! ordered per-edge copy lists and the tailcall preparation records —
//! the planning surface that allocation (cycle-type detection),
//! budgeting (edge-copy counts), and emission (the records themselves)
//! all replay through the same `edgeCopyList`, so sized and emitted
//! records agree by construction. Nothing in the input CFG is mutated
//! (Stilla LLIR Specification §1).

const std = @import("std");
const cfg = @import("stilla").cfg;
const llir = @import("stilla").llir;
const lower = @import("cfg_lower_llir.zig");
const lifecycle = @import("cfg_lower_lifecycle.zig");

const Builder = lower.Builder;

/// One phi-elimination edge copy: write `op` with operands
/// `(a = dst, b = src)` at the end of the predecessor edge.
pub const EdgeCopy = struct {
    op: llir.Opcode,
    dst: u32,
    src: u32,
    /// The source value's type — cycle staging matches staging slots by
    /// it (v1 has no slot-type rows).
    src_type: ?*const cfg.Type = null,
    /// For `slot_*` records the imm16 window offset (the write position
    /// inside the outgoing call area); 0 otherwise.
    imm: u32 = 0,
};

/// Plan the stage-7 LLIR-only edge blocks: after lifecycle planning
/// (so the per-edge `edgeKills` exist) and before budgeting, expand the
/// global block order by appending one synthetic block per distinct
/// effect-bearing outgoing edge of each CFG block — `j` and `br`/`switch`
/// arms alike. Every edge with phi copies or lifecycle kills routes
/// through its edge block, so only the selected edge's effects execute
/// (TODO.md 7.1). Each synthetic block has empty `instrs`, a `.j`
/// terminator to the real successor, and holds (in its record list) that
/// edge's ordered phi copies then lifecycle kills. `block_ids` and
/// `block_ranges` are rebuilt over the expanded order; the input CFG is
/// never mutated. `ordered_funcs`/`func_descs` are unchanged (edge
/// blocks belong to their predecessor's function range).
pub fn planBlocks(bld: *Builder) error{OutOfMemory}!void {
    const arena = bld.arena;
    const orig_blocks = try arena.alloc(*const cfg.BasicBlock, bld.ordered_blocks.items.len);
    @memcpy(orig_blocks, bld.ordered_blocks.items);
    const orig_ranges = try arena.alloc(lower.BlockRange, bld.block_ranges.items.len);
    @memcpy(orig_ranges, bld.block_ranges.items);
    bld.ordered_blocks.clearRetainingCapacity();
    bld.block_ids.clearRetainingCapacity();
    bld.block_ranges.clearRetainingCapacity();
    for (orig_ranges) |r| {
        const start: u32 = @intCast(bld.ordered_blocks.items.len);
        for (r.start..r.start + r.len) |gi| {
            const pred = orig_blocks[gi];
            try bld.block_ids.put(arena, pred, @intCast(bld.ordered_blocks.items.len));
            try bld.ordered_blocks.append(arena, pred);
            var succs = std.ArrayList(*cfg.BasicBlock).empty;
            var seen = std.AutoHashMapUnmanaged(*cfg.BasicBlock, void){};
            try effectSuccessors(bld, pred, &succs, &seen);
            for (succs.items) |succ| {
                const eb = try arena.create(cfg.BasicBlock);
                eb.* = .{
                    .id = pred.id, // sentinel — not read by the LLIR lowering
                    .span = pred.span,
                    .name = "",
                    .instrs = &.{},
                    .terminator = .{ .j = succ },
                    .preds = &.{},
                };
                try bld.block_ids.put(arena, eb, @intCast(bld.ordered_blocks.items.len));
                try bld.ordered_blocks.append(arena, eb);
                try bld.edge_blocks.put(arena, .{ .pred = pred, .succ = succ }, eb);
                try bld.edge_block_srcs.put(arena, eb, .{ .pred = pred, .succ = succ });
            }
        }
        try bld.block_ranges.append(arena, .{ .start = start, .len = @intCast(bld.ordered_blocks.items.len - start) });
    }
}

/// The distinct successors of `pred`'s out-edges whose edge carries
/// phi copies or lifecycle kills — the edges that get an LLIR-only edge
/// block. `ret`/`tailcall`/`trap` contribute none (no out-edges; a
/// tailcall's prep is not an edge effect). `succ` blocks are
/// deduped (a `switch` may repeat an arm target).
fn effectSuccessors(
    bld: *Builder,
    pred: *const cfg.BasicBlock,
    out: *std.ArrayList(*cfg.BasicBlock),
    seen: *std.AutoHashMapUnmanaged(*cfg.BasicBlock, void),
) error{OutOfMemory}!void {
    const check = struct {
        fn f(
            b: *Builder,
            pr: *const cfg.BasicBlock,
            succ: *cfg.BasicBlock,
            o: *std.ArrayList(*cfg.BasicBlock),
            s: *std.AutoHashMapUnmanaged(*cfg.BasicBlock, void),
        ) error{OutOfMemory}!void {
            if (s.contains(succ)) return;
            if (!hasPhiCopies(b, pr, succ) and lifecycle.edgeKills(b, pr, succ).len == 0) return;
            try s.put(b.arena, succ, {});
            try o.append(b.arena, succ);
        }
    };
    switch (pred.terminator) {
        .j => |t| try check.f(bld, pred, t, out, seen),
        .br => |b| {
            try check.f(bld, pred, b.then_, out, seen);
            try check.f(bld, pred, b.else_, out, seen);
        },
        .@"switch" => |s| for (s.arms) |arm| try check.f(bld, pred, arm.block, out, seen),
        else => {},
    }
}

/// Whether edge `pred → succ` has any non-self phi copy — the cheap
/// structural query `planBlocks` uses (before budgeting, so before
/// `block_edge_starts` exists; cycle staging is irrelevant here).
pub fn hasPhiCopies(bld: *const Builder, pred: *const cfg.BasicBlock, succ: *const cfg.BasicBlock) bool {
    for (succ.instrs) |ins| switch (ins.op) {
        .phi => |p| for (p.incoming) |in_| {
            if (in_.pred != pred) continue;
            if (bld.slotOf(ins.results[0]) != bld.slotOf(in_.value)) return true;
        },
        else => break,
    };
    return false;
}

/// Emit every edge's effects as ordinary records in its LLIR-only edge
/// block (stage 7): a synthetic edge block holds its edge's ordered phi
/// copies then lifecycle kills; ordinary CFG blocks emit NO inline edge
/// effects — every outgoing edge with copies or kills routes through an
/// edge block, so only the selected edge's effects execute. The tailcall
/// preparation is control emit's job. The opcode carries the ownership, so
/// no runtime state is consulted. Ordering and self-loop elision live in
/// `edgeCopyList`; back-edge swap cycles are broken through scratch.
pub fn run(bld: *Builder) error{OutOfMemory}!void {
    for (bld.ordered_blocks.items) |blk| {
        const bi = bld.block_ids.get(blk).?;
        if (bld.isEdgeBlock(blk)) {
            const edge = bld.edge_block_srcs.get(blk).?;
            var idx = bld.non_phi_counts.items[bi];
            idx = try emitEdgeCopies(bld, edge.pred, blk, idx, edge.succ);
            idx = try emitEdgeKills(bld, blk, idx, lifecycle.edgeKills(bld, edge.pred, edge.succ));
            std.debug.assert(idx == bld.non_phi_counts.items[bi] + bld.edge_copy_counts.items[bi]);
        } else {
            // Ordinary blocks hold no inline edge effects; the tailcall's
            // `edge_copy_counts` row covers the slot_* prep + leftover kills
            // that control emit places.
            if (std.meta.activeTag(blk.terminator) != .tailcall) {
                std.debug.assert(bld.edge_copy_counts.items[bi] == 0);
            }
        }
    }
}

/// Emit one edge's copy list into `target`'s records at block-local
/// `idx`; the list is computed for edge `pred → succ` (for an edge
/// block, `pred` is the source CFG block — its slots and dead-slot
/// cutoff drive cycle staging). Returns the index after them.
fn emitEdgeCopies(bld: *Builder, pred: *const cfg.BasicBlock, target: *const cfg.BasicBlock, idx: u32, succ: *const cfg.BasicBlock) error{OutOfMemory}!u32 {
    const list = try edgeCopyList(bld, pred, succ);
    var i = idx;
    for (list) |c| {
        bld.setE(target, i, c.op, c.dst, c.src);
        i += 1;
    }
    return i;
}

/// Emit one edge's lifecycle kills into `target`'s records at `idx`.
fn emitEdgeKills(bld: *Builder, target: *const cfg.BasicBlock, idx: u32, kills: []const lifecycle.Rec) error{OutOfMemory}!u32 {
    var i = idx;
    for (kills) |k| {
        bld.setE(target, i, k.op, k.a, k.b);
        i += 1;
    }
    return i;
}

/// The phi-elimination copy list for edge `pred → succ`,
/// ordered so every source is read before its destination is written
/// (reverse topological order of the copy graph):
/// a copy whose source is another copy's destination runs
/// first. Trivial self-loops (`src == dst`) are elided. A cycle
/// among the remaining copies — the back-edge swap `%x = phi [..:
/// %y], %y = phi [..: %x]` — is broken through a type-matched scratch
/// slot in the frame's scratch region `[V, V + S)`: the
/// cycle's source is staged (`scratch ← src`, same opcode — a unique
/// cycle stages with `move`, a view cycle with `borrow`), the remaining
/// cycle copies run in order, and the staged value lands last. A
/// k-cycle emits k + 1 records (one staging + k transfers). The staging
/// slot is `V + phi_type_rank`. The budget counts through this same
/// function, so reserved and emitted records always agree.
pub fn edgeCopyList(bld: *const Builder, pred: *const cfg.BasicBlock, succ: *const cfg.BasicBlock) error{OutOfMemory}![]const EdgeCopy {
    var copies = std.ArrayList(EdgeCopy).empty;
    for (succ.instrs) |ins| {
        switch (ins.op) {
            .phi => |p| {
                for (p.incoming) |in_| {
                    if (in_.pred != pred) continue;
                    const dst = bld.slotOf(ins.results[0]);
                    const src = bld.slotOf(in_.value);
                    if (src == dst) continue; // self-loop elided
                    const op: llir.Opcode = if (in_.value.state == .borrowed)
                        .borrow
                    else if (in_.value.ownership == .unique)
                        .move
                    else if (llir.modeOf(in_.value.type_) == .counted)
                        .copy_retain // v1: a copied counted value retains
                    else
                        .copy;
                    try copies.append(bld.arena, .{ .op = op, .dst = dst, .src = src, .src_type = &in_.value.type_ });
                }
            },
            else => break, // phis are block-head
        }
    }
    const n = copies.items.len;
    if (n < 2) return copies.items; // trivially ordered
    const emitted = try bld.arena.alloc(bool, n);
    @memset(emitted, false);
    var out = std.ArrayList(EdgeCopy).empty;
    var left: usize = n;
    while (left > 0) {
        var picked: ?usize = null;
        for (copies.items, 0..) |c, i| {
            if (emitted[i]) continue;
            var depends = false;
            for (copies.items, 0..) |d, j| {
                if (emitted[j]) continue;
                if (d.src == c.dst) { // j reads c's destination: j first
                    depends = true;
                    break;
                }
            }
            if (!depends) {
                picked = i;
                break;
            }
        }
        if (picked) |i| {
            try out.append(bld.arena, copies.items[i]);
            emitted[i] = true;
            left -= 1;
            continue;
        }
        // The unemitted copies form cycle(s): break one through a
        // type-matched scratch slot. Stage c0's source, then walk the cycle in order
        // (each next copy reads the previous dst, which its own
        // predecessor just wrote), and land the staged value last.
        var c0i: usize = 0;
        while (emitted[c0i]) c0i += 1;
        const c0 = copies.items[c0i];
        const source_type = c0.src_type.?;
        var staging: u32 = undefined;
        if (bld.detect_cycle_types) |sink| {
            // cycle-type detection (inside allocateSlots, before the scratch
            // rows exist): record the cycle type (deduped) and use a
            // placeholder id. The placeholder never enters the
            // copy-graph matching — staging ids appear only as record
            // dsts/srcs, never as copy-graph nodes — so detection and
            // emission run the identical walk.
            var known_type = false;
            for (sink.items) |k| {
                if (cfg.Type.eql(k.*, source_type.*)) known_type = true;
            }
            if (!known_type) try sink.append(bld.arena, source_type);
            staging = std.math.maxInt(u32);
        } else {
            staging = cycleStagingSlotForType(bld, pred, source_type.*, c0.src, c0.dst, copies.items);
        }
        try out.append(bld.arena, .{ .op = c0.op, .dst = staging, .src = c0.src });
        var cur = c0;
        while (true) {
            var next_i: ?usize = null;
            for (copies.items, 0..) |d, j| {
                if (emitted[j]) continue;
                if (d.src == cur.dst) {
                    next_i = j;
                    break;
                }
            }
            const j = next_i orelse unreachable; // cycle must close
            if (j == c0i) {
                // Back at c0: land the staged value into c0's dst.
                try out.append(bld.arena, .{ .op = c0.op, .dst = c0.dst, .src = staging });
                emitted[c0i] = true;
                left -= 1;
                break;
            }
            try out.append(bld.arena, copies.items[j]);
            emitted[j] = true;
            left -= 1;
            cur = copies.items[j];
        }
    }
    return out.items;
}

/// Edge-copy count for one edge — `.len` of the same list the emit walk
/// produces, kept separate so `budget` (which runs before the emit
/// stages) and `run` cannot disagree.
pub fn edgeCopyCount(bld: *Builder, pred: *const cfg.BasicBlock, succ: *const cfg.BasicBlock) error{OutOfMemory}!u32 {
    const list = try edgeCopyList(bld, pred, succ);
    return @intCast(list.len);
}

/// The first cycle-staging slot — retained for callers that only
/// need a representative staging id (the function has at least one
/// phi-cycle type by construction). The `no_index` forbids match
/// nothing: any free cell of the type is a valid representative.
pub fn cycleStagingSlot(bld: *const Builder, blk: *const cfg.BasicBlock) u32 {
    const fi = bld.funcIndexOfBlock(blk);
    const first = bld.scratch_cycle_types.items[fi].items[0];
    return cycleStagingSlotForType(bld, blk, first.*, llir.no_index, llir.no_index, &.{});
}

/// The type-matched staging slot for a phi-cycle copy on edge
/// `pred → succ` (the edge's dead-slot cutoff is `block_edge_starts`):
/// the lowest dead F cell of the cycle's type — one no record in the
/// edge's copy list writes (the staging write must not clobber a
/// destination any copy transfers into: acyclic copies run before the
/// cycle) — or the dedicated scratch cell `V + rank` past the value
/// cells when none is dead. `forbid_a`/`forbid_b` are the staged
/// copy's own src/dst *encodings* (avoid noop staging/landing copies);
/// `copies`
/// is the edge's raw phi-copy list (empty for the representative
/// query). Returns the staging cell's register *encoding*.
fn cycleStagingSlotForType(bld: *const Builder, blk: *const cfg.BasicBlock, type_: cfg.Type, forbid_a: u32, forbid_b: u32, copies: []const EdgeCopy) u32 {
    const fi = bld.funcIndexOfBlock(blk);
    const fd = bld.func_descs.items[fi];
    const f = bld.ordered_funcs.items[fi];
    const pred_bi = bld.block_ids.get(blk).?;
    const edge_start = bld.block_edge_starts.items[pred_bi];
    const cycle_types = bld.scratch_cycle_types.items[fi].items;
    for (cycle_types, 0..) |known, rank| {
        if (!cfg.Type.eql(known.*, type_)) continue;
        var values_base: u32 = 0;
        for (0..fi) |i| values_base += @intCast(bld.ordered_funcs.items[i].values.len);
        for (f.values, 0..) |v, vi| {
            const s = bld.value_slots.get(v) orelse continue;
            if (s >= fd.f_count) continue; // staging reuses dead F cells only
            const enc = llir.frameReg(s);
            if (enc == forbid_a or enc == forbid_b) continue; // avoid noop staging/landing copies
            var conflicts = false;
            for (copies) |c| {
                if (enc == c.dst) {
                    conflicts = true;
                    break;
                }
            }
            if (conflicts) continue; // another copy writes this cell: the stage would clobber it
            // v1 has no slot-type rows: the value's own type is the
            // slot's type by construction.
            if (!cfg.Type.eql(v.type_, type_)) continue;
            if (bld.value_ends.items[values_base + vi] < edge_start) return enc;
        }
        // Staging cells sit past the value cells: f_count counts
        // values + staging (+1 spill-stage when the function spills —
        // `x_count > 0` — a reserved cell that routes spilled values
        // through restricted operand positions), so subtract both the
        // staging count and the spill stage back out.
        return llir.frameReg(fd.f_count - @as(u32, @intCast(cycle_types.len)) - @intFromBool(fd.x_count > 0) + @as(u32, @intCast(rank)));
    }
    unreachable; // detection recorded every cycle type before emission
}

/// v1: the tailcall's pre-terminator record overhead —
/// the `slot_*` preparation records (one per parameter, no staging,
/// no cycles) plus the leftover-owner kills.
pub fn tailcallOverhead(bld: *Builder, blk: *const cfg.BasicBlock) error{OutOfMemory}!u32 {
    const n_args: u32 = switch (blk.terminator) {
        .tailcall => |tc| @intCast(tc.args.len),
        else => return 0,
    };
    const kills: u32 = @intCast(lifecycle.tailcallKills(bld, blk).len);
    return n_args + kills;
}

/// The tailcall preparation records: one `slot_*` per parameter at
/// its absolute outgoing-window offset, then the leftover-owner kill
/// records, in emission order (prepare all new
/// parameters first, then explicitly consume undestroyed old F/X
/// owners before the jump). The old parallel-copy staging and cycle
/// breaking are gone: the window is not register-aliased, so there
/// is nothing to permute.
pub fn tailcallPrepRecords(bld: *Builder, blk: *const cfg.BasicBlock) error{OutOfMemory}![]const EdgeCopy {
    const tc = switch (blk.terminator) {
        .tailcall => |t| t,
        else => return &.{},
    };
    const fi = bld.funcIndexOfBlock(blk);
    const fd = bld.func_descs.items[fi];
    const p: u32 = @intCast(tc.args.len);
    const base = fd.window_count - p;
    var out = std.ArrayList(EdgeCopy).empty;
    for (tc.args, 0..) |a, k| {
        // A self-tailcall's signature is this function's own:
        // borrowed parameters re-borrow (stable views), everything
        // else transfers or retains into the window.
        const op: llir.Opcode = if (a.state == .borrowed)
            .slot_borrow
        else if (a.ownership == .unique)
            .slot_move
        else if (llir.modeOf(a.type_) == .counted)
            .slot_retain
        else
            .slot_copy;
        try out.append(bld.arena, .{
            .op = op,
            .dst = bld.slotOf(a),
            .src = 0,
            .src_type = &a.type_,
            .imm = base + @as(u32, @intCast(k)),
        });
    }
    for (lifecycle.tailcallKills(bld, blk)) |k| {
        try out.append(bld.arena, .{ .op = k.op, .dst = k.a, .src = k.b });
    }
    return out.items;
}
