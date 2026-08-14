//! Pass: local common subexpression elimination over module references
//! and member loads (frontend.md §8.4). In: a lowered `cfg.IrProgram`
//! (after tail-call elimination). Out: the same program, with an
//! identical `module_ref` earlier in the same block reused, and an
//! identical `load_member` of the same module slot (whose result is
//! Copy) reused, so repeated module/member reads fold to one load.
//!
//! `module_ref` is a pure constant: the module handle is the same value
//! on every reference, so an identical reference earlier in the block is
//! reused. `load_member` reads a module slot; module storage is written
//! only by `store_member` inside `@init` (cfg_validate rejects a store
//! anywhere else, ir.md §5.6), so a slot's value is stable for the life
//! of a function — a repeated load of the same slot from the same module
//! value is redundant unless a `store_member` intervenes, which clears
//! the table. Only Copy results are shared, mirroring the
//! on-the-fly CSE rule: a Copy member read is a copy, an unique
//! read is a borrowed view, and sharing a view across uses would change
//! the destruction schedule (ir.md §6.4).
//!
//! The rewrite is in-block: the canonical definition sits earlier in the
//! same block, so it dominates the later value and every use of it — in
//! this block and in every block the later value's block dominates —
//! making the use-rewrite sound. Values are renumbered in text order
//! afterwards (ir.md §13). Allocations use the program's backing
//! allocator (the arena); the pass frees nothing.

const std = @import("std");
const cfg = @import("../cfg.zig");

/// The load_member key: the module value and the member read.
const LoadKey = struct {
    module: *cfg.Value,
    member: u32,
};

/// Eliminate redundant `module_ref` / `load_member` computations.
pub fn cse(program: *cfg.IrProgram, allocator: std.mem.Allocator) !void {
    for (program.funcs) |f| {
        try cseFunc(f, allocator);
    }
}

fn cseFunc(f: *cfg.IrFunc, allocator: std.mem.Allocator) !void {
    var mods = std.StringHashMapUnmanaged(*cfg.Value){}; // specifier -> canonical module_ref
    defer mods.deinit(allocator);
    var loads = std.AutoHashMapUnmanaged(LoadKey, *cfg.Value){};
    defer loads.deinit(allocator);
    for (f.blocks) |b| {
        // Per-block tables: an earlier block's canonical may not dominate
        // this block, so only in-block reuse is sound.
        mods.clearRetainingCapacity();
        loads.clearRetainingCapacity();
        var out = std.ArrayList(*cfg.Instr).empty;
        for (b.instrs) |instr| {
            switch (instr.op) {
                .module_ref => |spec| {
                    if (mods.get(spec)) |canon| {
                        cfg.rewriteUses(f, instr.results[0], canon);
                        continue; // drop the redundant reference
                    }
                    try mods.put(allocator, spec, instr.results[0]);
                },
                .load_member => |lm| {
                    if (instr.results.len > 0 and (instr.results[0].ownership orelse .copy) != .unique) {
                        const key = LoadKey{ .module = lm.module, .member = lm.member };
                        if (loads.get(key)) |canon| {
                            cfg.rewriteUses(f, instr.results[0], canon);
                            continue;
                        }
                        try loads.put(allocator, key, instr.results[0]);
                    }
                },
                .store_member => {
                    // The stored slot's value is now fresh: the table is
                    // stale. (Stores are @init-only, so this is a
                    // bookkeeping edge, not a hot path.)
                    loads.clearRetainingCapacity();
                },
                else => {},
            }
            try out.append(allocator, instr);
        }
        b.instrs = try out.toOwnedSlice(allocator);
    }
    try cfg.renumberValues(f, allocator);
}
