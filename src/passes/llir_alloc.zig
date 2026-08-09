//! Pass: LLIR register allocation — the 2.3 linear-scan value→F-cell
//! mapping plus the v1 per-function frame layout numbers (spec §4.1).
//! In: the `Builder` after 2.1 dense ID allocation. Out: the
//! `value_slots` map, the `f_count`/`x_count`/`window_count` layout
//! numbers, and the `value_ends` snapshot — everything the emission
//! stages read. Parameters keep the ABI cells `F0..F(P-1)`; later values
//! reuse ANY expired F cell regardless of type (v1 cells are untyped
//! host words, Instruction Set §9); copy/move results coalesce with their
//! source; phi-cycle staging cells follow the value cells. Values are
//! never placed in the outgoing window: the O suffix
//! `[f_count, f_count + window_count)` is reserved for the call area
//! (the header reserve + output window, all call-clobbered — spec
//! §4.1, §5). When the combined demand — F cells plus the window —
//! exceeds the register bank (`frame_count_max` = 109, i.e.
//! `L + 3 + O <= 109`), excess live ranges move to X spill cells (the
//! spill decision lives here; the record expansion is the separate
//! `llir_expand_spills.zig` pass, and the post-allocation Step 8
//! result coalescing is `llir_result_coalesce.zig`).
const std = @import("std");
const cfg = @import("stilla").cfg;
const llir = @import("stilla").llir;
const patterns = @import("llir_patterns.zig");
const lower = @import("cfg_lower_llir.zig");
const cfg_order = @import("llir_cfg_order.zig");

const Builder = lower.Builder;

const SlotInfo = struct {
    type_: *const cfg.Type,
    end: u32,
    active: bool,
};

const Interval = struct {
    value: *const cfg.Value,
    start: u32,
    end: u32,
};

/// A spilled live range: the value lives in an X cell for its whole
/// interval. Its records carry a free sentinel byte in the T range
/// (`temp_base .. temp_base + 11`) instead of an F register; the
/// pre-linearize rewrite (`expandSpills`) replaces each such field with
/// a T staging register surrounded by take/put records.
const SpillInterval = struct {
    value: *const cfg.Value,
    end: u32,
    x_cell: u32,
};

fn intervalLess(_: void, a: Interval, b: Interval) bool {
    return if (a.start == b.start) a.value.id < b.value.id else a.start < b.start;
}

// ---------------------------------------------------------------------------
// Driver
// ---------------------------------------------------------------------------

/// Allocate every function's frame and fill the v1 `FunctionDesc`
/// numbers (`f_count`, `x_count`, `window_count`; spec §4.1).
pub fn allocateSlots(bld: *Builder) error{OutOfMemory}!void {
    for (bld.ordered_funcs.items, 0..) |f, fi| {
        var slots = std.ArrayList(SlotInfo).empty;
        const linear = try allocateFunctionSlots(bld, f, &slots);
        if (!linear) {
            // Defensive dense fallback: one permanent cell per value.
            slots.clearRetainingCapacity();
            for (f.values) |v| {
                try bld.value_slots.put(bld.arena, v, v.id);
                try slots.append(bld.arena, .{ .type_ = &v.type_, .end = std.math.maxInt(u32), .active = true });
            }
        }
        // Cycle staging types: detection replays the emit walk with
        // `detect_cycle_types` armed; each distinct staging type gets a
        // dedicated cell after the value cells (the 2.8 semantics — v1
        // keeps the cells, drops the type rows).
        var cycle_types = std.ArrayList(*const cfg.Type).empty;
        bld.detect_cycle_types = &cycle_types;
        for (f.blocks) |blk| {
            switch (blk.terminator) {
                .j => |t| _ = try bld.edgeCopyList(blk, t),
                .br => |b| {
                    _ = try bld.edgeCopyList(blk, b.then_);
                    _ = try bld.edgeCopyList(blk, b.else_);
                },
                .@"switch" => |s| for (s.arms) |arm| {
                    _ = try bld.edgeCopyList(blk, arm.block);
                },
                else => {},
            }
        }
        bld.detect_cycle_types = null;
        try bld.scratch_cycle_types.append(bld.arena, cycle_types);

        // Spill (Instruction Set §5): while the direct bank overflows, live
        // ranges move to X cells (their records are expanded by
        // `expandSpills` after emission). The victims are chosen at the
        // peak-liveness position — the values occupying cells where the
        // scan's cell demand is maximal — so each spill provably reduces
        // the peak by one and the survivors always fit the bank. The scan's
        // cell table is never mutated in place (no `swapRemove`): after the
        // loop, `value_slots` is rebuilt dense for the survivors (0..k-1)
        // and spilled values map to their T-range sentinel bytes, which the
        // emitters write into register fields and `expandSpills` rewrites.
        const cycle_len: u32 = @intCast(cycle_types.items.len);
        var spills = std.ArrayList(SpillInterval).empty;
        // Parameter cells are pinned to the ABI range F0..F(P-1) and can
        // never move to X — if the pinned cells alone overflow the bank,
        // the function is not encodable (ProgramTooLarge).
        const pinned: u32 = @intCast(@min(f.params.len, slots.items.len));
        // Per-function interval data (the scan appended one entry per value
        // in `f.values` order, across all functions).
        var values_base: u32 = 0;
        for (0..fi) |i| values_base += @intCast(bld.ordered_funcs.items[i].values.len);
        const starts = bld.value_starts.items[values_base .. values_base + f.values.len];
        const ends = bld.value_ends.items[values_base .. values_base + f.values.len];
        // Cells → values for THIS function (the scan's assignment; coalesced
        // values share a cell). A cell is the spill unit: every value on a
        // spilled cell goes to X, and the cell is freed. Iterating `f.values`
        // keeps the buckets free of other functions' entries — `value_slots`
        // is a Builder-wide map whose per-function value ids collide.
        var cell_values = std.ArrayList(std.ArrayList(*const cfg.Value)).empty;
        for (0..slots.items.len) |_| try cell_values.append(bld.arena, .empty);
        for (f.values) |v| {
            const sl = bld.value_slots.get(v).?;
            if (sl < cell_values.items.len) try cell_values.items[sl].append(bld.arena, v);
        }
        var freed_cells = std.AutoHashMapUnmanaged(u32, void){};
        // v10 budget (spec §4.1): the window counts against the same
        // 109-register bank as the F cells (`L + 3 + O <= 109`), so the
        // spill trigger demands cells + window, not cells alone. The
        // window itself never shrinks by spilling (it is fixed by the
        // call sites); an over-window demand drains to the pinned-only
        // exit below and flags `operand_overflow`.
        const window: u32 = @intCast(windowSize(bld, f));
        while (slots.items.len - freed_cells.count() + cycle_len + @intFromBool(spills.items.len > 0) + window > llir.frame_count_max) {
            // Peak-liveness position over the survivors: the position with
            // the most occupied cells, using the scan's liveness convention
            // (a value leaves its cell when `end < p`; `end == p` and
            // `start == p` share a cell via the in-place rule).
            var peak: usize = 0;
            var argmax: u32 = 0;
            for (f.values) |v0| {
                if (bld.spill_bytes.get(v0) != null) continue;
                const p = starts[v0.id];
                var count: usize = 0;
                for (0..slots.items.len) |ci| {
                    if (freed_cells.contains(@intCast(ci))) continue;
                    var occupied = false;
                    for (cell_values.items[ci].items) |w| {
                        if (bld.spill_bytes.get(w) != null) continue;
                        if (starts[w.id] <= p and p <= ends[w.id]) {
                            occupied = true;
                            break;
                        }
                    }
                    if (occupied) count += 1;
                }
                if (count > peak) {
                    peak = count;
                    argmax = p;
                }
            }
            // The occupiers at the argmax: per cell, the value with the
            // latest (start, id) among the live, non-spilled ones (the
            // in-place rule: the later-starting value holds the shared
            // cell). Spill the cell whose occupier has the latest end
            // (furthest deadline — the longest-lived ranges leave first).
            var victims = std.ArrayList(*const cfg.Value).empty;
            var victim_cells = std.ArrayList(u32).empty;
            for (0..slots.items.len) |ci| {
                if (freed_cells.contains(@intCast(ci))) continue;
                if (ci < pinned) continue; // ABI-pinned cells never spill
                var occupier: ?*const cfg.Value = null;
                for (cell_values.items[ci].items) |w| {
                    if (bld.spill_bytes.get(w) != null) continue;
                    if (starts[w.id] <= argmax and argmax <= ends[w.id]) {
                        if (occupier == null or starts[w.id] > starts[occupier.?.id] or
                            (starts[w.id] == starts[occupier.?.id] and w.id > occupier.?.id))
                        {
                            occupier = w;
                        }
                    }
                }
                if (occupier) |o| {
                    try victims.append(bld.arena, o);
                    try victim_cells.append(bld.arena, @intCast(ci));
                }
            }
            if (victims.items.len == 0) {
                bld.operand_overflow = true; // the peak is entirely pinned
                return;
            }
            var best: usize = 0;
            for (victims.items, 0..) |o, i| {
                if (ends[o.id] > ends[victims.items[best].id]) best = i;
            }
            const victim_cell = victim_cells.items[best];
            for (cell_values.items[victim_cell].items) |w| {
                if (bld.spill_bytes.get(w) != null) continue;
                const xc: u32 = @intCast(spills.items.len);
                try spills.append(bld.arena, .{ .value = w, .end = ends[w.id], .x_cell = xc });
                const byte: u8 = llir.temp_base + @as(u8, @intCast(spills.items.len));
                if (byte >= llir.temp_base + llir.temp_count - 1) {
                    // Ceiling: at most 15 simultaneously distinct spilled
                    // values per function (the T0–T14 sentinel codes —
                    // T15 is reserved for the 32-bit normalization
                    // staging of the widthless arithmetic sequences, so
                    // the next byte would collide with it).
                    // ponytail: revisit with per-position T assignment if a
                    // real function ever hits this.
                    bld.operand_overflow = true;
                    return;
                }
                try bld.spill_bytes.put(bld.arena, w, byte);
                try bld.spill_x.put(bld.arena, byte, xc);
            }
            try freed_cells.put(bld.arena, victim_cell, {});
        }

        // Rebuild a dense value_slots over the surviving cells. The scan's
        // slot ids now have holes (every freed cell); emission reads
        // `value_slots` for every operand, so survivors must map to the
        // dense 0..k-1 range the FunctionDesc promises, and spilled values
        // to their sentinel bytes (the record fields `expandSpills` keys on).
        var remap = std.AutoHashMapUnmanaged(u32, u32){};
        var next: u32 = 0;
        for (0..slots.items.len) |ci| {
            if (freed_cells.contains(@intCast(ci))) continue;
            try remap.put(bld.arena, @intCast(ci), next);
            next += 1;
        }
        {
            for (f.values) |v| {
                if (bld.spill_bytes.get(v)) |byte| {
                    try bld.value_slots.put(bld.arena, v, byte);
                } else {
                    const old = bld.value_slots.get(v).?;
                    try bld.value_slots.put(bld.arena, v, remap.get(old).?);
                }
            }
        }

        const fd = &bld.func_descs.items[fi];
        // One extra F cell when the function spills: the reserved staging
        // register that routes spilled values through restricted operand
        // positions (ret sources, branch operands, call results/targets,
        // slot_* sources — Instruction Set §5 allows only F/special there).
        fd.f_count = @intCast(next + cycle_len + @intFromBool(spills.items.len > 0));
        fd.x_count = @intCast(spills.items.len);
        fd.window_count = @intCast(window);
    }
}

/// The outgoing-window size: max over call/tailcall sites of `3 + A`
/// (spec §4.1, §5.5 — a self-tailcall reuses this function's window as
/// its argument staging), where `A = max(parameter_count,
/// result_count)` and the result count is 0 or 1. Indirect callees
/// resolve through the function value's signature type; unresolved
/// direct callees scan the program by
/// name (the optimizer fills `DirectCallee.func` later).
fn windowSize(bld: *Builder, f: *const cfg.IrFunc) u32 {
    var w: u32 = 0;
    for (f.blocks) |blk| {
        for (blk.instrs) |ins| {
            if (std.meta.activeTag(ins.op) != .call) continue;
            const c = ins.op.call;
            const p: u32 = switch (c.callee) {
                .direct => |d| blk: {
                    if (d.func) |fun| break :blk @intCast(fun.params.len);
                    for (bld.program.funcs) |fun| {
                        if (std.mem.eql(u8, fun.name.text, d.name)) break :blk @intCast(fun.params.len);
                    }
                    break :blk 0;
                },
                .value => |v| switch (v.type_) {
                    .function => |ft| @intCast(ft.params.len),
                    else => 0,
                },
            };
            const r: u32 = if (ins.results.len > 0) 1 else 0;
            w = @max(w, 3 + @max(p, r));
        }
        switch (blk.terminator) {
            .tailcall => |tc| w = @max(w, @as(u32, @intCast(tc.args.len)) + 3),
            else => {},
        }
    }
    return w;
}

// ---------------------------------------------------------------------------
// Linear scan (2.3)
// ---------------------------------------------------------------------------

/// One function's value cells — a linear scan over liveness intervals.
/// Blocks are positioned in DFS reverse post-order (RPO respects
/// dominance on any CFG, loops included), and each value's interval end
/// is extended through every block where the value is live-out — the
/// iterative liveness fixed point keeps a loop-invariant value used only
/// at the header live through the latch. Returns `false` only from the
/// defensive dense fallback.
///
/// v1: the scan is NOT type-constrained — any expired F cell may hold
/// any type (cells are untyped host words); coalescing still requires
/// equal types because copy/move share the source's cell contents.
fn allocateFunctionSlots(bld: *Builder, f: *const cfg.IrFunc, slots: *std.ArrayList(SlotInfo)) error{OutOfMemory}!bool {
    const n = f.blocks.len;
    const nv = f.values.len;

    const seen = try bld.arena.alloc(bool, n);
    @memset(seen, false);
    var post = std.ArrayList(*cfg.BasicBlock).empty;
    try cfg_order.appendPostOrder(bld, f, f.entry, seen, &post);
    for (f.blocks) |blk| try cfg_order.appendPostOrder(bld, f, blk, seen, &post);
    std.debug.assert(post.items.len == n);
    const order = post.items;
    std.mem.reverse(*cfg.BasicBlock, order);

    const starts = try bld.arena.alloc(u32, n);
    const term_pos = try bld.arena.alloc(u32, n);
    var point: u32 = 0;
    for (order) |blk| {
        const bi = cfg_order.blockIndex(f.blocks, blk);
        starts[bi] = point;
        for (blk.instrs) |_| point += 1;
        term_pos[bi] = point;
        point += 1;
    }

    const starts_by_value = try bld.arena.alloc(u32, nv);
    const ends = try bld.arena.alloc(u32, nv);
    const uses = try bld.arena.alloc(u32, nv);
    @memset(starts_by_value, std.math.maxInt(u32));
    @memset(ends, 0);
    @memset(uses, 0);
    for (f.values[0..f.params.len], 0..) |v, i| {
        starts_by_value[i] = 0;
        try bld.value_slots.put(bld.arena, v, @intCast(i));
    }

    // Per-block def/use bitsets for the liveness fixed point. Phi
    // incomings are uses on the matching predecessor edge.
    const def_bits = try bld.arena.alloc(std.DynamicBitSetUnmanaged, n);
    const use_bits = try bld.arena.alloc(std.DynamicBitSetUnmanaged, n);
    for (f.blocks, 0..) |blk, bi| {
        def_bits[bi] = try std.DynamicBitSetUnmanaged.initEmpty(bld.arena, nv);
        use_bits[bi] = try std.DynamicBitSetUnmanaged.initEmpty(bld.arena, nv);
        for (blk.instrs) |ins| {
            for (ins.results) |result| def_bits[bi].set(result.id);
        }
    }
    for (f.values[0..f.params.len]) |param_value| def_bits[cfg_order.blockIndex(f.blocks, f.entry)].set(param_value.id);
    for (order) |blk| {
        const bi = cfg_order.blockIndex(f.blocks, blk);
        for (blk.instrs, 0..) |ins, ii| {
            const pos = starts[bi] + @as(u32, @intCast(ii));
            for (ins.results) |result| starts_by_value[result.id] = pos;
            try markOpUses(ins.op, ends, uses, pos, if (std.meta.activeTag(ins.op) == .phi) null else &use_bits[bi]);
            if (std.meta.activeTag(ins.op) == .phi) {
                const phi = ins.op.phi;
                for (phi.incoming) |incoming| {
                    const pred_bi = cfg_order.blockIndex(f.blocks, incoming.pred);
                    markUse(ends, uses, incoming.value, term_pos[pred_bi], null);
                    use_bits[pred_bi].set(incoming.value.id);
                }
            }
        }
        try markTermUses(blk.terminator, ends, uses, term_pos[bi], &use_bits[bi]);
    }
    for (f.values) |v| if (starts_by_value[v.id] == std.math.maxInt(u32)) return allocateNaiveSlots(bld, f, slots);
    for (f.values) |v| ends[v.id] = @max(ends[v.id], starts_by_value[v.id]);

    // Iterative liveness to the fixed point over reverse RPO.
    const live_in = try bld.arena.alloc(std.DynamicBitSetUnmanaged, n);
    const live_out = try bld.arena.alloc(std.DynamicBitSetUnmanaged, n);
    for (f.blocks, 0..) |_, bi| {
        live_in[bi] = try std.DynamicBitSetUnmanaged.initEmpty(bld.arena, nv);
        live_out[bi] = try std.DynamicBitSetUnmanaged.initEmpty(bld.arena, nv);
    }
    var changed = true;
    while (changed) {
        changed = false;
        var ri = n;
        while (ri > 0) {
            ri -= 1;
            const blk = order[ri];
            const bi = cfg_order.blockIndex(f.blocks, blk);
            const before = live_in[bi].count();
            for (try cfg_order.succsOf(bld, blk.terminator)) |succ| {
                live_out[bi].setUnion(live_in[cfg_order.blockIndex(f.blocks, succ)]);
            }
            live_in[bi].setUnion(use_bits[bi]);
            var it = live_out[bi].iterator(.{});
            while (it.next()) |vid| {
                if (!def_bits[bi].isSet(vid)) live_in[bi].set(vid);
            }
            if (live_in[bi].count() != before) changed = true;
        }
    }
    // A value live out of a block survives up to that block's terminator.
    for (f.blocks, 0..) |_, bi| {
        var it = live_out[bi].iterator(.{});
        while (it.next()) |vid| ends[vid] = @max(ends[vid], term_pos[bi]);
    }

    for (f.values[0..f.params.len]) |v| {
        try slots.append(bld.arena, .{ .type_ = &v.type_, .end = ends[v.id], .active = uses[v.id] != 0 });
    }
    const intervals = try bld.arena.alloc(Interval, f.values.len - f.params.len);
    for (f.values[f.params.len..], 0..) |v, i| intervals[i] = .{ .value = v, .start = starts_by_value[v.id], .end = ends[v.id] };
    std.mem.sort(Interval, intervals, {}, intervalLess);
    for (intervals) |interval| {
        const value = interval.value;
        if (coalesceSource(f, value, uses)) |source| {
            const source_slot = bld.value_slots.get(source) orelse return allocateNaiveSlots(bld, f, slots);
            const source_end = slots.items[source_slot].end;
            if (source_end <= interval.start and patterns.canInPlace(value)) {
                bld.value_slots.put(bld.arena, value, source_slot) catch return error.OutOfMemory;
                slots.items[source_slot].end = @max(slots.items[source_slot].end, interval.end);
                slots.items[source_slot].active = true;
                continue;
            }
        }
        for (slots.items) |*slot| {
            if (slot.active and slot.end < interval.start) slot.active = false;
        }
        var chosen: ?u32 = null;
        if (value.def) |def| if (std.meta.activeTag(def.op) == .phi) {
            const phi = def.op.phi;
            var multi: ?*const cfg.BasicBlock = null;
            var multi_count: usize = 0;
            for (phi.incoming) |incoming| {
                switch (incoming.pred.terminator) {
                    .br, .@"switch" => {
                        multi = incoming.pred;
                        multi_count += 1;
                    },
                    else => {},
                }
            }
            if (multi_count <= 1) {
                for (phi.incoming) |incoming| {
                    if (multi_count == 1 and incoming.pred != multi.?) continue;
                    const candidate = bld.value_slots.get(incoming.value) orelse continue;
                    if (candidate < slots.items.len and slots.items[candidate].end < interval.start) {
                        chosen = candidate;
                        break;
                    }
                }
            }
        };
        // v1: unrestricted dead-cell reuse — any expired cell fits any
        // type (Instruction Set §9). The phi-incoming coalescing above keeps its
        // guard so jump-threaded edges stay correct.
        if (chosen == null) for (slots.items, 0..) |slot, i| {
            if (!slot.active) chosen = @intCast(i);
        };
        if (chosen == null and patterns.canInPlace(value)) {
            // In-place reuse of a slot whose occupant dies exactly at
            // this instruction: the result record writes the cell the
            // result is allocated. Skip it when the dying occupant is a
            // counted comparison operand — its lifecycle release fires
            // AFTER this instruction's records (the release must read
            // the cell once more), so the in-place result record would
            // clobber the cell first and the release would decrement
            // the wrong value (a `str_eq` result released as if it were
            // the compared string — forged-pointer trap).
            var counted_dies_here = false;
            if (value.def) |def| switch (def.op) {
                .eq, .ne, .lt, .le, .gt, .ge => |bin| {
                    if (llir.modeOf(bin.a.type_) == .counted and ends[bin.a.id] == interval.start) counted_dies_here = true;
                    if (llir.modeOf(bin.b.type_) == .counted and ends[bin.b.id] == interval.start) counted_dies_here = true;
                },
                else => {},
            };
            if (!counted_dies_here) {
                for (slots.items, 0..) |slot, i| {
                    if (slot.active and slot.end == interval.start) {
                        chosen = @intCast(i);
                        break;
                    }
                }
            }
        }
        const slot = chosen orelse @as(u32, @intCast(slots.items.len));
        if (chosen == null) {
            try slots.append(bld.arena, .{ .type_ = &value.type_, .end = interval.end, .active = true });
        } else {
            slots.items[slot].end = interval.end;
            slots.items[slot].active = true;
        }
        try bld.value_slots.put(bld.arena, value, slot);
    }
    // Snapshot interval ends for dead-slot detection in
    // cycleStagingSlotForType — one entry per value, in value order,
    // appended across all functions.
    for (f.values) |v| {
        try bld.value_ends.append(bld.arena, ends[v.id]);
        try bld.value_starts.append(bld.arena, starts_by_value[v.id]);
    }
    return true;
}

fn allocateNaiveSlots(bld: *Builder, f: *const cfg.IrFunc, slots: *std.ArrayList(SlotInfo)) error{OutOfMemory}!bool {
    slots.clearRetainingCapacity();
    for (f.values) |v| {
        try bld.value_slots.put(bld.arena, v, v.id);
        try slots.append(bld.arena, .{ .type_ = &v.type_, .end = std.math.maxInt(u32), .active = true });
        // The defensive fallback models every value as live forever from
        // position 0 — keep the interval snapshot aligned.
        try bld.value_ends.append(bld.arena, std.math.maxInt(u32));
        try bld.value_starts.append(bld.arena, 0);
    }
    return false;
}

fn coalesceSource(f: *const cfg.IrFunc, value: *const cfg.Value, uses: []const u32) ?*const cfg.Value {
    const def = value.def orelse return null;
    switch (def.op) {
        .copy, .move_ => |source| {
            if (cfg.Type.eql(source.type_, value.type_)) return source;
            return null;
        },
        .add => |bin| {
            const product = if (patterns.isMulResult(bin.b)) bin.b else if (patterns.isMulResult(bin.a) and Builder.isInteger(bin.b.type_)) bin.a else return null;
            const accumulator = if (product == bin.b) bin.a else bin.b;
            if (uses[product.id] != 1 or uses[accumulator.id] != 1) return null;
            for (f.blocks) |blk| {
                for (blk.instrs, 0..) |ins, i| {
                    if (ins == def and i > 0 and blk.instrs[i - 1] == product.def.?) return accumulator;
                }
            }
        },
        else => {},
    }
    return null;
}

// ---------------------------------------------------------------------------
// CFG walk helpers
// ---------------------------------------------------------------------------

fn markUse(ends: []u32, uses: []u32, v: *const cfg.Value, pos: u32, set: ?*std.DynamicBitSetUnmanaged) void {
    ends[v.id] = @max(ends[v.id], pos);
    uses[v.id] += 1;
    if (set) |s| s.set(v.id);
}

fn markOpUses(op: cfg.Op, ends: []u32, uses: []u32, pos: u32, set: ?*std.DynamicBitSetUnmanaged) error{OutOfMemory}!void {
    switch (op) {
        .const_, .module_ref, .fn_ref => {},
        .neg, .abs, .clz, .popcount, .not_, .num_cast, .any_pack_copy, .any_pack_move, .any_unpack_copy, .any_unpack_move, .copy, .borrow, .move_, .drop_, .cleanup_arm, .cleanup_disarm, .cleanup_drop, .tail, .unpack_struct, .unpack_tuple, .split_list, .read_tag, .read_payload => |v| markUse(ends, uses, v, pos, set),
        .add, .sub, .mul, .div, .rem, .min, .max, .shl, .shr, .bitand, .bitor, .bitxor, .concat, .eq, .ne, .lt, .le, .gt, .ge => |b| {
            markUse(ends, uses, b.a, pos, set);
            markUse(ends, uses, b.b, pos, set);
        },
        .select => |s| {
            markUse(ends, uses, s.cond, pos, set);
            markUse(ends, uses, s.a, pos, set);
            markUse(ends, uses, s.b, pos, set);
        },
        .type_is => |ti| markUse(ends, uses, ti.value, pos, set),
        .read_field, .read_tuple => |p| markUse(ends, uses, p.base, pos, set),
        .read_index => |ix| {
            markUse(ends, uses, ix.base, pos, set);
            markUse(ends, uses, ix.index, pos, set);
        },
        .unpack_variant => |uv| markUse(ends, uses, uv.base, pos, set),
        .borrow_variant => |bv| markUse(ends, uses, bv.base, pos, set),
        .load_member => |lm| markUse(ends, uses, lm.module, pos, set),
        .store_member => |sm| markUse(ends, uses, sm.value, pos, set),
        .construct => |c| for (c.args) |a| markUse(ends, uses, a, pos, set),
        .call => |c| {
            switch (c.callee) {
                .direct => {},
                .value => |v| markUse(ends, uses, v, pos, set),
            }
            for (c.args) |a| markUse(ends, uses, a, pos, set);
        },
        .syscall => |s| for (s.args) |a| markUse(ends, uses, a, pos, set),
        .phi => {},
    }
}

fn markTermUses(term: cfg.Terminator, ends: []u32, uses: []u32, pos: u32, set: ?*std.DynamicBitSetUnmanaged) error{OutOfMemory}!void {
    switch (term) {
        .ret => |v| if (v) |value| markUse(ends, uses, value, pos, set),
        .j, .trap => {},
        .br => |b| {
            markUse(ends, uses, b.cond, pos, set);
            // A fused compare-and-branch reads the comparison's own
            // operands at the terminator (cfg_lower_llir
            // fusedBranchReads): keep them live to this point, or the
            // comparison's `copy dst, cond` materialization can land
            // in a shared slot and clobber them before the branch
            // reads them.
            if (Builder.fusedBranchReads(b.cond)) |reads| {
                markUse(ends, uses, reads.a, pos, set);
                if (reads.b) |rhs| markUse(ends, uses, rhs, pos, set);
            }
        },
        .@"switch" => |s| markUse(ends, uses, s.disc, pos, set),
        .tailcall => |tc| for (tc.args) |a| markUse(ends, uses, a, pos, set),
    }
}
