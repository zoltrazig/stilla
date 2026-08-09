//! Shared CFG ordering utilities for the LLIR lowering passes — the
//! successor walk, the DFS post-order/RPO construction, and the
//! block-index lookup. Every pass that positions instructions (the
//! 2.3 linear scan, the Step 8 result coalescing) must derive its
//! positions through these exact helpers: the liveness snapshots
//! (`value_starts`/`value_ends`) and the coalescer's call-clobber
//! check share one position space, so the orderings must never drift.
const std = @import("std");
const cfg = @import("stilla").cfg;
const lower = @import("cfg_lower_llir.zig");

const Builder = lower.Builder;

pub fn succsOf(bld: *Builder, term: cfg.Terminator) error{OutOfMemory}![]*cfg.BasicBlock {
    var out = std.ArrayList(*cfg.BasicBlock).empty;
    switch (term) {
        .j => |t| try out.append(bld.arena, t),
        .br => |b| {
            try out.append(bld.arena, b.then_);
            try out.append(bld.arena, b.else_);
        },
        .@"switch" => |s| for (s.arms) |arm| try out.append(bld.arena, arm.block),
        .ret, .tailcall, .trap => {},
    }
    return out.items;
}

pub fn appendPostOrder(bld: *Builder, f: *const cfg.IrFunc, root: *cfg.BasicBlock, seen: []bool, post: *std.ArrayList(*cfg.BasicBlock)) error{OutOfMemory}!void {
    const root_bi = blockIndex(f.blocks, root);
    if (seen[root_bi]) return;
    seen[root_bi] = true;
    const Frame = struct { bi: usize, succ_i: usize };
    var stack = std.ArrayList(Frame).empty;
    try stack.append(bld.arena, .{ .bi = root_bi, .succ_i = 0 });
    while (stack.pop()) |top| {
        const succs = try succsOf(bld, f.blocks[top.bi].terminator);
        if (top.succ_i < succs.len) {
            var next = top;
            next.succ_i += 1;
            try stack.append(bld.arena, next);
            const s_bi = blockIndex(f.blocks, succs[top.succ_i]);
            if (!seen[s_bi]) {
                seen[s_bi] = true;
                try stack.append(bld.arena, .{ .bi = s_bi, .succ_i = 0 });
            }
        } else {
            try post.append(bld.arena, f.blocks[top.bi]);
        }
    }
}

pub fn blockIndex(blocks: []*cfg.BasicBlock, block: *cfg.BasicBlock) usize {
    for (blocks, 0..) |candidate, i| if (candidate == block) return i;
    unreachable;
}
