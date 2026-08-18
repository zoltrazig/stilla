//! Pass: copy propagation (optimizer.md, Pass 8 driver). In: a lowered
//! `cfg.IrProgram` (after drop elision, so the unobservable drops of
//! Copy values are already gone). Out: the same program, with every
//! `copy` of a Copy value replaced by the value itself, so
//! copy-of-copy chains collapse and a copied parameter that is directly
//! returned passes the parameter through.
//!
//! A `copy` of a Copy value does nothing at runtime (Core §10.1 —
//! destruction is unobservable, and the ownership classification
//! guarantees a Copy type never runs a user drop hook), so the
//! result is interchangeable with the operand: every use of the result is
//! rewritten to the operand and the copy is removed. The operand's
//! definition dominates the copy's result, which dominates every use, so
//! the rewrite is sound. Unique copies are never touched: their
//! refcount/ownership transfer is observable (ir.md §6.4).
//!
//! One pass over the blocks suffices: `rewriteUses` scans the whole
//! function, so a copy processed early collapses uses in every block,
//! including copies that later become chains of length one. Values are
//! renumbered in text order afterwards (ir.md §13). Allocations use the
//! program's backing allocator (the arena); the pass frees nothing.

const std = @import("std");
const cfg = @import("../cfg.zig");

/// Collapse every `copy` of a Copy value into the value itself.
pub fn copyProp(program: *cfg.IrProgram, allocator: std.mem.Allocator) !void {
    for (program.funcs) |f| {
        try copyPropFunc(f, allocator);
    }
}

fn copyPropFunc(f: *cfg.IrFunc, allocator: std.mem.Allocator) !void {
    for (f.blocks) |b| {
        var out = std.ArrayList(*cfg.Instr).empty;
        for (b.instrs) |instr| {
            if (instr.op == .copy and instr.results.len > 0 and (instr.results[0].ownership orelse .copy) != .unique) {
                cfg.rewriteUses(f, instr.results[0], instr.op.copy);
                continue; // drop the copy
            }
            try out.append(allocator, instr);
        }
        b.instrs = try out.toOwnedSlice(allocator);
    }
    try cfg.renumberValues(f, allocator);
}
