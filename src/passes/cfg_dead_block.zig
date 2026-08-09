//! Pass: dead-block elimination (optimizer.md, Pass 8.3). In: a lowered
//! `cfg.IrProgram` (after constant folding, common subexpression
//! elimination, partial redundancy elimination, and copy propagation). Out:
//! the same program, with every block unreachable from the entry removed.
//!
//! A block is reachable exactly when the entry block can branch to it
//! through terminator edges; every other block is dead and is removed. The
//! surviving blocks' predecessor sets are rebuilt to drop edges from
//! removed blocks, and each phi's incoming list is rebuilt to match — the
//! incoming-list contract (air.md §4.3) requires one entry per predecessor,
//! in predecessor order. No surviving terminator needs editing: any block a
//! surviving block branches to is reachable by construction.
//!
//! Removing blocks also removes their values, so the function's value table
//! is rebuilt and renumbered in text order, dropping every value no longer
//! defined (air.md §13). An SSA use of a dead-block value can only live in
//! another dead block — a use requires its definition to dominate the use
//! block — so no surviving instruction dangles. The pass is
//! *trap-preserving* (Runtime §7.2): an unreachable block never runs.
//! Block ids are not part of the text form, so id gaps are harmless.
//! Allocations use the program's backing allocator (the arena); the pass
//! frees nothing.

const std = @import("std");
const cfg = @import("stilla").cfg;

/// Remove every block not reachable from the entry.
pub fn deadBlock(program: *cfg.IrProgram, allocator: std.mem.Allocator) !void {
    for (program.funcs) |f| {
        try pruneFunc(f, allocator);
    }
}

/// Remove `f`'s unreachable blocks, rebuild predecessor sets and phi
/// incoming lists, and renumber the surviving values in text order.
fn pruneFunc(f: *cfg.IrFunc, allocator: std.mem.Allocator) !void {
    const reachable = try marks(f, allocator);
    defer allocator.free(reachable);

    // Surviving blocks, in original order (renumber re-sorts for print).
    var blocks = std.ArrayList(*cfg.BasicBlock).empty;
    for (f.blocks) |b| {
        if (reachable[b.id]) try blocks.append(allocator, b);
    }
    f.blocks = try blocks.toOwnedSlice(allocator);

    for (f.blocks) |b| {
        try pruneBlock(b, reachable, allocator);
    }
    try cfg.renumberValues(f, allocator);
}

/// Reachability marks: `true` for every block reachable from the entry
/// through terminator edges.
fn marks(f: *cfg.IrFunc, allocator: std.mem.Allocator) ![]bool {
    // Sized by the largest block id: a prior dead-block pass may already
    // have removed blocks, leaving id gaps (air.md §13).
    var max_id: usize = 0;
    for (f.blocks) |b| max_id = @max(max_id, b.id);
    const seen = try allocator.alloc(bool, max_id + 1);
    @memset(seen, false);
    var work = std.ArrayList(*cfg.BasicBlock).empty;
    defer work.deinit(allocator);
    seen[f.entry.id] = true;
    try work.append(allocator, f.entry);
    while (work.pop()) |b| {
        switch (b.terminator) {
            .ret, .tailcall, .trap => {},
            .j => |succ| {
                if (!seen[succ.id]) {
                    seen[succ.id] = true;
                    try work.append(allocator, succ);
                }
            },
            .br => |bc| {
                for ([_]*cfg.BasicBlock{ bc.then_, bc.else_ }) |succ| {
                    if (!seen[succ.id]) {
                        seen[succ.id] = true;
                        try work.append(allocator, succ);
                    }
                }
            },
            .@"switch" => |s| for (s.arms) |arm| {
                if (!seen[arm.block.id]) {
                    seen[arm.block.id] = true;
                    try work.append(allocator, arm.block);
                }
            },
        }
    }
    return seen;
}

/// Rebuild `b`'s predecessor set and phi incoming lists to drop edges from
/// removed blocks. The phi incoming list is rebuilt to match the surviving
/// predecessors in order, preserving the air.md §4.3 contract.
fn pruneBlock(b: *cfg.BasicBlock, reachable: []const bool, allocator: std.mem.Allocator) !void {
    var preds = std.ArrayList(*cfg.BasicBlock).empty;
    for (b.preds) |p| {
        if (reachable[p.id]) try preds.append(allocator, p);
    }
    b.preds = try preds.toOwnedSlice(allocator);

    for (b.instrs) |instr| {
        if (instr.op != .phi) continue;
        const phi = &instr.op.phi;
        var incoming = std.ArrayList(cfg.PhiIn).empty;
        for (phi.incoming) |inc| {
            if (reachable[inc.pred.id]) try incoming.append(allocator, inc);
        }
        phi.incoming = try incoming.toOwnedSlice(allocator);
    }
}
