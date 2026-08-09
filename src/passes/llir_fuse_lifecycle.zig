//! Pass: ownership lifecycle fusion — the record-pair fusions the
//! emitter cannot do in one shot. In: the `Builder` after
//! `llir_fusion.peephole` and `llir_compact_noop_ownership.zig`. Out:
//! adjacent pairs folded block-locally — `release d; copy_retain d, s`
//! → `replace_copy d, s`, `release d; move d, s` → `replace_move d, s`,
//! and the block-final `release x; ret result` →
//! `release_ret result, x` — with the non-phi record counts re-derived
//! afterward. PCs still do not exist (2.16 linearizes afterward).
const std = @import("std");
const llir = @import("stilla").llir;
const lower = @import("cfg_lower_llir.zig");

const Builder = lower.Builder;

pub fn fuseLifecycle(b: *Builder) error{OutOfMemory}!u32 {
    var fused: u32 = 0;
    for (b.block_records.items, 0..) |*recs, bi| {
        if (recs.items.len < 2) continue;
        var out = std.ArrayList(llir.Instr).empty;
        var i: usize = 0;
        const n = recs.items.len;
        while (i < n) : (i += 1) {
            const rec = recs.items[i];
            const d = llir.decode(rec) orelse {
                try out.append(b.arena, rec);
                continue;
            };
            if (d.op != .release or i + 1 >= n) {
                try out.append(b.arena, rec);
                continue;
            }
            const next = recs.items[i + 1];
            const nd = llir.decode(next);
            // release d; copy_retain d, s  =>  replace_copy d, s
            if (nd != null and nd.?.op == .copy_retain and nd.?.a == d.a) {
                try out.append(b.arena, llir.instrE(.replace_copy, nd.?.a, nd.?.b));
                i += 1;
                fused += 1;
                continue;
            }
            // release d; move d, s  =>  replace_move d, s — only when
            // the move's destination is the released slot, exactly like
            // the copy_retain arm: `release F0; move F1, F2` must not
            // fuse, or the F0 release is dropped and F1's old occupant
            // is never released (replace_move would take it over).
            if (nd != null and nd.?.op == .move and nd.?.a == d.a) {
                try out.append(b.arena, llir.instrE(.replace_move, nd.?.a, nd.?.b));
                i += 1;
                fused += 1;
                continue;
            }
            // release x; ret result  =>  release_ret result, x — the pair
            // must be exactly the block's final two records (the cleanup
            // source is consumed as control transfers away).
            if (i == n - 2) {
                const last = recs.items[n - 1];
                if (llir.decode(last)) |ld| {
                    if (ld.op == .ret and ld.a != d.a) {
                        try out.append(b.arena, llir.instrE(.release_ret, ld.a, d.a));
                        i += 1;
                        fused += 1;
                        continue;
                    }
                }
            }
            try out.append(b.arena, rec);
        }
        recs.* = out;
        // Deleted records sit in the instruction region (lifecycle
        // releases are trailing records of instructions), so shrink the
        // non-phi count like compactNoopOwnership does.
        const edge_len = b.edge_copy_counts.items[bi];
        const terms = b.terminatorRecordCount(b.ordered_blocks.items[bi]);
        b.non_phi_counts.items[bi] = @intCast(out.items.len - edge_len - terms);
    }
    return fused;
}
