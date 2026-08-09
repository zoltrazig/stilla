//! Pass: same-slot ownership-transfer cleanup — after the fusion
//! peephole, records whose take/copy semantics degenerate to a no-op
//! (`copy`/`borrow`/`move`/`copy_retain` with identical source and
//! destination) are deleted block-locally, and the block's non-phi
//! record count is re-derived so the budget bookkeeping stays exact.
//! In: the `Builder` after `llir_fusion.peephole`. Out: compacted
//! record lists; PCs still do not exist (2.16 linearizes afterward).
const std = @import("std");
const llir = @import("stilla").llir;
const lower = @import("cfg_lower_llir.zig");

const Builder = lower.Builder;

pub fn compactNoopOwnership(bld: *Builder) error{OutOfMemory}!void {
    for (bld.block_records.items, 0..) |*recs, bi| {
        var kept = std.ArrayList(llir.Instr).empty;
        for (recs.items) |rec| if (!isNoopOwnership(rec)) try kept.append(bld.arena, rec);
        recs.* = kept;
        const edge_len = bld.edge_copy_counts.items[bi];
        const terms = bld.terminatorRecordCount(bld.ordered_blocks.items[bi]);
        bld.non_phi_counts.items[bi] = @intCast(kept.items.len - edge_len - terms);
    }
}

fn isNoopOwnership(rec: llir.Instr) bool {
    const d = llir.decode(rec) orelse return false;
    return switch (d.op) {
        .copy, .borrow, .move, .copy_retain => d.a == d.b,
        else => false,
    };
}
