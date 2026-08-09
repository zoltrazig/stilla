//! Pass: jump threading (frontend.md §8.8). In: a lowered `cfg.IrProgram`
//! (after dead-block elimination and drop elision). Out: the same program,
//! with empty forwarding blocks removed.
//!
//! A forwarding block is one with no instructions whose terminator is an
//! unconditional `br` to a single successor — the lowerer's trivial
//! `then:`/`else:` branches of an `if`, and the noise-only joins of void
//! control flow. Threading removes it: every predecessor's edge to the
//! block is redirected to its ultimate successor, and the successor's phi
//! incoming entries for the block are re-keyed to the block's own
//! predecessors. Because a forwarding block is empty, the value flowing
//! through it on every in-edge is the same, so one phi entry splits into
//! one entry per predecessor (ir.md §4.3 keeps phi incoming and
//! predecessor order in lockstep).
//!
//! The rewrite is semantics-preserving: an empty block performs no work,
//! so redirecting edges and re-keying phis changes nothing observable.
//! Chains of forwarding blocks collapse to their ultimate successor (the
//! walk follows `br` edges while the target is itself a forwarding
//! candidate); a chain cycle makes every member non-threadable. A
//! candidate whose predecessor already branches directly to the ultimate
//! target is skipped, so threading never creates a duplicate predecessor
//! edge (which the printer's phi ordering cannot distinguish).
//!
//! The pass is single-pass (no fixpoint — frontend.md §6): a chain
//! collapsed in one pass may leave one forwarding block behind, which a
//! later optimization invocation removes. Allocations use the program's
//! backing allocator (the arena); the pass frees nothing.

const std = @import("std");
const cfg = @import("../cfg.zig");

/// Remove every empty forwarding block of the program.
pub fn jumpThread(program: *cfg.IrProgram, allocator: std.mem.Allocator) !void {
    for (program.funcs) |f| {
        try threadFunc(f, allocator);
    }
}

/// Thread `f`'s forwarding blocks and renumber the surviving values.
fn threadFunc(f: *cfg.IrFunc, allocator: std.mem.Allocator) !void {
    // Block ids may have gaps (dead-block removal drops blocks without
    // renumbering — ir.md §13: ids are not part of the text form), so
    // id-indexed arrays are sized by the largest id, not the block
    // count.
    var max_id: usize = 0;
    for (f.blocks) |b| max_id = @max(max_id, b.id);
    const n = max_id + 1;
    const removed = try allocator.alloc(bool, n);
    defer allocator.free(removed);
    @memset(removed, false);
    // Ultimate successor per candidate block (null for non-candidates and
    // for candidates on a chain cycle).
    const ult = try allocator.alloc(?*cfg.BasicBlock, n);
    defer allocator.free(ult);
    for (f.blocks) |b| ult[b.id] = null;

    const candidates = try collectCandidates(f, allocator);
    defer allocator.free(candidates);
    for (candidates) |x| {
        ult[x.id] = try ultimateOf(f, x, allocator);
    }

    // One pass, in block order: thread each removable candidate.
    for (f.blocks) |x| {
        const t = ult[x.id] orelse continue;
        if (removed[x.id]) continue;
        var ok = true;
        for (x.preds) |p| {
            if (removed[p.id]) continue;
            if (referencesTarget(p, t)) {
                ok = false;
                break;
            }
        }
        if (!ok) continue;
        for (x.preds) |p| {
            if (removed[p.id]) continue;
            try retarget(p, x, t, allocator);
        }
        removed[x.id] = true;
    }

    var any = false;
    for (removed) |r| any = any or r;
    if (!any) return;

    const orig_blocks = f.blocks;
    var blocks = std.ArrayList(*cfg.BasicBlock).empty;
    for (orig_blocks) |b| {
        if (!removed[b.id]) try blocks.append(allocator, b);
    }
    f.blocks = try blocks.toOwnedSlice(allocator);

    // Rebuild each surviving block's predecessor set and phi incoming
    // lists in lockstep: surviving old predecessors keep their phi entry,
    // and each threaded candidate's own predecessors inherit the entry
    // that referenced the candidate (the value is the same on every
    // in-edge of the empty block).
    for (f.blocks) |b| {
        try rebuildBlock(b, orig_blocks, removed, ult, allocator);
    }
    try cfg.renumberValues(f, allocator);
}

/// The forwarding candidates of `f`: blocks with no instructions, an
/// unconditional `br` to a block other than themselves, and not the entry.
fn collectCandidates(f: *const cfg.IrFunc, allocator: std.mem.Allocator) ![]*cfg.BasicBlock {
    var out = std.ArrayList(*cfg.BasicBlock).empty;
    for (f.blocks) |b| {
        if (b == f.entry) continue;
        if (b.instrs.len != 0) continue;
        const t = switch (b.terminator) {
            .branch => |t| t,
            else => continue,
        };
        if (t == b) continue;
        try out.append(allocator, b);
    }
    return out.toOwnedSlice(allocator);
}

/// The ultimate successor of candidate `x`: follow its `br` chain while
/// the target is itself a forwarding candidate. Null when the chain cycles
/// (the candidate is not threadable).
fn ultimateOf(f: *const cfg.IrFunc, x: *cfg.BasicBlock, allocator: std.mem.Allocator) !?*cfg.BasicBlock {
    var visited = std.AutoHashMap(*cfg.BasicBlock, void).init(allocator);
    defer visited.deinit();
    var cur = x;
    while (true) {
        if (visited.contains(cur)) return null; // cycle
        try visited.put(cur, {});
        const t = switch (cur.terminator) {
            .branch => |t| t,
            else => return cur,
        };
        if (t == cur) return null; // self-loop, not a candidate anyway
        if (!isCandidate(f, t)) return t;
        cur = t;
    }
}

/// True when `b` qualifies as a forwarding candidate under the current
/// block list (used by the ultimate walk).
fn isCandidate(f: *const cfg.IrFunc, b: *const cfg.BasicBlock) bool {
    if (b == f.entry) return false;
    if (b.instrs.len != 0) return false;
    const t = switch (b.terminator) {
        .branch => |t| t,
        else => return false,
    };
    return t != b;
}

/// True when `p`'s terminator currently has an edge to `t`.
fn referencesTarget(p: *const cfg.BasicBlock, t: *const cfg.BasicBlock) bool {
    return switch (p.terminator) {
        .branch => |b| b == t,
        .branch_cond => |bc| bc.then_ == t or bc.else_ == t,
        .@"switch" => |s| blk: {
            for (s.arms) |a| if (a.block == t) break :blk true;
            break :blk false;
        },
        else => false,
    };
}

/// Redirect every edge of `p`'s terminator that targets `x` to `t`.
/// Reassigns the whole terminator (Zig unions cannot be mutated through
/// a payload capture of a loaded value).
fn retarget(p: *cfg.BasicBlock, x: *const cfg.BasicBlock, t: *cfg.BasicBlock, allocator: std.mem.Allocator) !void {
    switch (p.terminator) {
        .branch => |b| {
            if (b == x) p.terminator = .{ .branch = t };
        },
        .branch_cond => |bc| {
            if (bc.then_ == x or bc.else_ == x) {
                p.terminator = .{ .branch_cond = .{
                    .cond = bc.cond,
                    .then_ = if (bc.then_ == x) t else bc.then_,
                    .else_ = if (bc.else_ == x) t else bc.else_,
                } };
            }
        },
        .@"switch" => |s| {
            var any = false;
            var arms = std.ArrayList(cfg.SwitchArm).empty;
            for (s.arms) |a| {
                if (a.block == x) {
                    any = true;
                    try arms.append(allocator, .{ .tag = a.tag, .block = t });
                } else {
                    try arms.append(allocator, a);
                }
            }
            if (any) p.terminator = .{ .@"switch" = .{ .disc = s.disc, .arms = try arms.toOwnedSlice(allocator) } };
        },
        else => unreachable, // a predecessor must branch to x
    }
}

/// Rebuild `b`'s predecessor set and phi incoming lists after threading.
/// `orig_blocks` is the pre-threading block list (ids index `removed`);
/// entries that referenced a threaded candidate are re-keyed to the
/// candidate's own (surviving) predecessors, in lockstep with the new
/// predecessor order.
fn rebuildBlock(
    b: *cfg.BasicBlock,
    orig_blocks: []*cfg.BasicBlock,
    removed: []const bool,
    ult: []const ?*cfg.BasicBlock,
    allocator: std.mem.Allocator,
) !void {
    var preds = std.ArrayList(*cfg.BasicBlock).empty;
    for (b.preds) |p| {
        if (!removed[p.id]) try preds.append(allocator, p);
    }
    for (orig_blocks) |x| {
        if (!removed[x.id]) continue;
        const t = ult[x.id] orelse unreachable;
        if (t != b) continue;
        for (x.preds) |p| {
            if (!removed[p.id]) try preds.append(allocator, p);
        }
    }
    b.preds = try preds.toOwnedSlice(allocator);

    for (b.instrs) |instr| {
        if (instr.op != .phi) continue;
        const phi = &instr.op.phi;
        // Snapshot the old pred → value map.
        var old = std.AutoHashMap(*cfg.BasicBlock, *cfg.Value).init(allocator);
        defer old.deinit();
        for (phi.incoming) |inc| try old.put(inc.pred, inc.value);
        var incoming = std.ArrayList(cfg.PhiIn).empty;
        for (b.preds) |p| {
            const v = if (old.get(p)) |v|
                v
            else blk: {
                // `p` inherits the entry of the threaded candidate it
                // used to feed (at most one — duplicate edges are
                // prevented by the pass's skip rule).
                var found: ?*cfg.Value = null;
                outer: for (orig_blocks) |x| {
                    if (!removed[x.id]) continue;
                    if (ult[x.id].? != b) continue;
                    for (x.preds) |xp| {
                        if (xp == p) {
                            found = old.get(x) orelse continue :outer;
                            break :outer;
                        }
                    }
                }
                break :blk found orelse unreachable;
            };
            try incoming.append(allocator, .{ .value = v, .pred = p });
        }
        phi.incoming = try incoming.toOwnedSlice(allocator);
    }
}
