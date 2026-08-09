//! Pass: Step 8 result coalescing for direct calls (spec §4.1, §5.4).
//! In: the `Builder` after the 2.3 allocation (`llir_alloc.zig`) — the
//! frame-layout numbers (`f_count`/`x_count`/`window_count`), the
//! value→slot map, and the liveness snapshots (`value_starts`/
//! `value_ends`) are final. Out: eligible call results remapped onto
//! the result alias itself, so the emitter drops the post-call `take`
//! (per-call instruction count 1 → 0).
//!
//! A non-void direct call's result lands in the caller register
//! `F(L+3+O-A)` (the callee's `ret` publishes it there). When the
//! result value's live range contains no other call — all O aliases
//! are call-clobbered — the pass remaps the value directly onto that
//! alias register. The former F cell is left allocated (no
//! compaction): `f_count` stays stable, so the alias arithmetic never
//! moves under the emitter or the budget pass.
//!
//! Only direct callees are eligible: an indirect (`jalr`) call keeps
//! its take, whose source encoding is the dynamic `A`-mismatch /
//! failure-atomicity check in `enterCall`. A candidate is rejected if
//! any window-writing record (another call, or a self-tailcall's arg
//! staging) occurs at position `p` with `def_pos < p <= ends` — the
//! coalesced value is call-clobbered and must die before the next
//! write. Positions come from the shared ordering helpers
//! (`llir_cfg_order.zig`) — exactly the positions the allocation
//! liveness snapshots use.
const std = @import("std");
const cfg = @import("stilla").cfg;
const llir = @import("stilla").llir;
const lower = @import("cfg_lower_llir.zig");
const cfg_order = @import("llir_cfg_order.zig");

const Builder = lower.Builder;

/// Coalesce every function's eligible direct-call results. Runs as its
/// own lowering step, immediately after `llir_alloc.allocateSlots`.
pub fn run(bld: *Builder) error{OutOfMemory}!void {
    for (bld.ordered_funcs.items, 0..) |f, fi| {
        try coalesceFunction(bld, f, fi, &bld.func_descs.items[fi]);
    }
}

fn coalesceFunction(bld: *Builder, f: *const cfg.IrFunc, fi: usize, fd: *llir.FunctionDesc) error{OutOfMemory}!void {
    // Same RPO instruction positions as the allocation linear scan —
    // the `value_starts`/`value_ends` snapshots are indexed in exactly
    // this order (llir_cfg_order.zig keeps the two from drifting).
    const n = f.blocks.len;
    const seen = try bld.arena.alloc(bool, n);
    @memset(seen, false);
    var post = std.ArrayList(*cfg.BasicBlock).empty;
    try cfg_order.appendPostOrder(bld, f, f.entry, seen, &post);
    for (f.blocks) |blk| try cfg_order.appendPostOrder(bld, f, blk, seen, &post);
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
    // Per-value interval data (one entry per value, in `f.values` order,
    // across all functions).
    var values_base: u32 = 0;
    for (0..fi) |i| values_base += @intCast(bld.ordered_funcs.items[i].values.len);
    const vstarts = bld.value_starts.items[values_base .. values_base + f.values.len];
    const vends = bld.value_ends.items[values_base .. values_base + f.values.len];
    // Positions of window-writing records: every call instruction and
    // every self-tailcall terminator (its `slot_*` staging writes the
    // window). A coalesced value must not be live across any of them.
    var writes = std.ArrayList(u32).empty;
    for (f.blocks) |blk| {
        const bi = cfg_order.blockIndex(f.blocks, blk);
        for (blk.instrs, 0..) |ins, ii| {
            if (std.meta.activeTag(ins.op) == .call)
                try writes.append(bld.arena, starts[bi] + @as(u32, @intCast(ii)));
        }
        if (std.meta.activeTag(blk.terminator) == .tailcall)
            try writes.append(bld.arena, term_pos[bi]);
    }
    std.mem.sort(u32, writes.items, {}, std.sort.asc(u32));
    for (f.values) |v| {
        const def = v.def orelse continue;
        if (std.meta.activeTag(def.op) != .call) continue;
        const c = def.op.call;
        if (c.callee != .direct) continue; // jalr keeps its take (dynamic contract)
        // A cross-module call lowers to `jalr` through the symbolic
        // import path: its take contract is dynamic, never coalesced.
        if (bld.isCrossModuleName(c.callee.direct.name)) continue;
        if (def.results.len != 1) continue;
        if (bld.spill_bytes.get(v) != null) continue; // spilled values stage through T
        const def_pos = vstarts[v.id];
        const end = vends[v.id];
        // Any window write strictly after the def and at/before the last
        // use clobbers the alias → keep the take.
        var clobbered = false;
        for (writes.items) |p| {
            if (p > def_pos and p <= end) {
                clobbered = true;
                break;
            }
        }
        if (clobbered) continue;
        const a: u32 = @max(@as(u32, @intCast(c.args.len)), 1);
        try bld.value_slots.put(bld.arena, v, fd.f_count + fd.window_count - a); // F(L+3+O-A)
    }
}
