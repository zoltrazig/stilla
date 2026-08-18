//! Pass: drop elision (frontend.md §8.6). In: a lowered `cfg.IrProgram`
//! (after dead-block elimination). Out: the same program, with every
//! `drop` / `trydrop` whose destruction is provably unobservable removed.
//!
//! A `drop` of a Copy value does nothing (Core §10.1) and — because
//! a type that defines a user `drop` hook is always classified unique
//! (type_shape.zig: a struct with a hook breaks :unique) — a Copy
//! value can never run Stilla code during destruction. Eliding it changes
//! nothing observable (ir.md §14: a user hook that performs output must
//! never be elided; the ownership classification guarantees it is not
//! Copy, so the rule never touches it). Values whose ownership is
//! deferred (`null`) or unique are left alone: their destruction may run
//! a hook or hand a payload to the host.
//!
//! `drop` is a pure effect (no result), so eliding it needs no use
//! rewriting; the function's value table is untouched and values are
//! renumbered (a no-op) only to keep the pass uniform with its peers.
//! Allocations use the program's backing allocator (the arena); the pass
//! frees nothing.

const std = @import("std");
const cfg = @import("../cfg.zig");

/// Remove every `drop` / `trydrop` of a Copy value.
pub fn dropElide(program: *cfg.IrProgram, allocator: std.mem.Allocator) !void {
    for (program.funcs) |f| {
        for (f.blocks) |b| {
            var out = std.ArrayList(*cfg.Instr).empty;
            for (b.instrs) |instr| {
                const v = switch (instr.op) {
                    .drop_ => |v| v,
                    // `cleanup_drop` / `cleanup_disarm` act on a
                    // cleanup token (type `.cleanup`, classified
                    // Copy) and must never be elided: the token's
                    // payload is an unique owner.
                    else => null,
                };
                if (v) |val| {
                    if (val.ownership == .copy) continue; // unobservable
                }
                try out.append(allocator, instr);
            }
            b.instrs = try out.toOwnedSlice(allocator);
        }
        try cfg.renumberValues(f, allocator);
    }
}
