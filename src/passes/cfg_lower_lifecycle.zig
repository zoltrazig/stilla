//! Pass: LLIR v1 lifecycle planning — counted-value `release` placement
//! and tailcall leftover consumption (Instruction Set §4, §4.3, §5.1). In: the
//! `Builder` after 2.3 slot allocation (value slots fixed). Out: the
//! per-instruction trailing destroy records, the per-edge kill records
//! folded into the edge-copy lists, and the per-tailcall leftover kills.
//!
//! Conditional ownership never reaches this pass: the frontend resolves
//! maybe-unique candidates at each construct's join (unconditional
//! `.drop_` effects on the non-consuming branch edges, Instruction Set §4), so
//! every remaining owner is uniformly alive or uniformly consumed at
//! every merge. What stays here is the counted half of the lifecycle:
//! a `str`/`list[T]`/`box[T]` value must `release` exactly once along
//! every path after its final non-consuming use — placed after the last
//! use inside its death block, or on the CFG edge that leaves the live
//! region (liveness-differential placement, which is merge-uniform by
//! construction: a value in `liveIn(s)` is never released on any edge
//! into `s`, and one outside is released on every edge that still held
//! it).
const std = @import("std");
const ast = @import("stilla").ast;
const cfg = @import("stilla").cfg;
const llir = @import("stilla").llir;
const lower = @import("cfg_lower_llir.zig");

const Builder = lower.Builder;

/// One synthetic lifecycle record (the fields of an exact LLIR `Instr`).
pub const Rec = struct {
    op: llir.Opcode,
    a: u32 = 0,
    b: u32 = 0,
    c: u32 = 0,
};

/// Plan the whole program's lifecycle records.
pub fn plan(bld: *Builder) error{OutOfMemory}!void {
    for (bld.ordered_funcs.items) |f| {
        try planFunc(bld, f);
    }
}

/// The trailing records of one instruction — counted values released
/// immediately after their final use. Empty for almost every
/// instruction.
pub fn trailingOf(bld: *const Builder, ins: *const cfg.Instr) []const Rec {
    return if (bld.release_trailing.get(ins)) |lst| lst.items else &.{};
}

/// The kill records of one CFG edge — appended after the edge-copy
/// list, before the terminator hand-off.
pub fn edgeKills(bld: *const Builder, pred: *const cfg.BasicBlock, succ: *const cfg.BasicBlock) []const Rec {
    return if (bld.release_edges.get(.{ .pred = pred, .succ = succ })) |lst| lst.items else &.{};
}

/// The leftover-owner kill records a tailcall emits after its `slot_*`
/// preparation (spec §5.5): every owner still alive at the terminator,
/// except sources this tailcall borrows — only borrow-mode parameters
/// may feed `slot_borrow`, and those are views, not owners, so nothing
/// needs exempting here.
pub fn tailcallKills(bld: *const Builder, blk: *const cfg.BasicBlock) []const Rec {
    return if (bld.tailcall_kills.get(blk)) |lst| lst.items else &.{};
}

// ---------------------------------------------------------------------------
// Per-function planning
// ---------------------------------------------------------------------------

const FnCtx = struct {
    bld: *Builder,
    f: *const cfg.IrFunc,
    /// Counted universe: candidate index by value pointer.
    idx: std.AutoHashMapUnmanaged(*const cfg.Value, usize) = .empty,
    n: usize = 0,
    /// Per-block sets over the counted universe, parallel to `f.blocks`.
    use_in: []std.DynamicBitSet,
    /// Full-occurrence set (not upward-exposed) — dead-def detection.
    used_anywhere: []std.DynamicBitSet,
    /// Counted values read by this block's non-consuming terminator
    /// (`br.cond`, `switch.disc`); `ret` and `tailcall` reads are
    /// excluded — those transfer/consume, they never need an edge
    /// release. Stage-7: a value whose only use is such a read must be
    /// released on the outgoing edges, after the terminator, not before
    /// it.
    term_reads: []std.DynamicBitSet,
    def_in: []std.DynamicBitSet,
    live_in: []std.DynamicBitSet,
    live_out: []std.DynamicBitSet,
};

fn planFunc(bld: *Builder, f: *const cfg.IrFunc) error{OutOfMemory}!void {
    const arena = bld.arena;
    var ctx = FnCtx{
        .bld = bld,
        .f = f,
        .use_in = try arena.alloc(std.DynamicBitSet, f.blocks.len),
        .used_anywhere = try arena.alloc(std.DynamicBitSet, f.blocks.len),
        .term_reads = try arena.alloc(std.DynamicBitSet, f.blocks.len),
        .def_in = try arena.alloc(std.DynamicBitSet, f.blocks.len),
        .live_in = try arena.alloc(std.DynamicBitSet, f.blocks.len),
        .live_out = try arena.alloc(std.DynamicBitSet, f.blocks.len),
    };
    // Universe: every counted OWNED value. Borrowed views (borrow-mode
    // parameters, `borrow` projections) never release — the owner does.
    for (f.values) |v| {
        if (llir.modeOf(v.type_) != .counted) continue;
        if (v.state == .borrowed) continue;
        try ctx.idx.put(arena, v, ctx.n);
        ctx.n += 1;
    }
    if (ctx.n == 0) {
        try planTailcallKills(&ctx);
        return;
    }
    for (0..f.blocks.len) |i| {
        ctx.use_in[i] = try std.DynamicBitSet.initEmpty(arena, ctx.n);
        ctx.used_anywhere[i] = try std.DynamicBitSet.initEmpty(arena, ctx.n);
        ctx.term_reads[i] = try std.DynamicBitSet.initEmpty(arena, ctx.n);
        ctx.def_in[i] = try std.DynamicBitSet.initEmpty(arena, ctx.n);
        ctx.live_in[i] = try std.DynamicBitSet.initEmpty(arena, ctx.n);
        ctx.live_out[i] = try std.DynamicBitSet.initEmpty(arena, ctx.n);
    }
    try scanUses(&ctx);
    try liveness(&ctx);
    try placeReleases(&ctx);
    try planTailcallKills(&ctx);
}

fn mark(ctx: *FnCtx, bs: *std.DynamicBitSet, v: *const cfg.Value) void {
    if (ctx.idx.get(v)) |i| bs.set(i);
}

/// Fill `use_in`/`def_in`: which counted values each block reads or
/// defines. Consuming uses (moves, consuming destructures, move-mode
/// arguments) count as uses too — they read the cell before killing it;
/// release placement filters them out afterwards. Terminator reads
/// (switch scrutinee, branch conditions, tailcall arguments) count as
/// block uses; phi inputs are read on the predecessor edge, so they are
/// added to each predecessor's use set in a second pass.
fn scanUses(ctx: *FnCtx) error{OutOfMemory}!void {
    const arena = ctx.bld.arena;
    for (ctx.f.blocks, 0..) |blk, bi| {
        var ops = std.ArrayList(*const cfg.Value).empty;
        defer ops.deinit(arena);
        // Upward-exposed uses only: a use preceded (in this block) by a
        // def of the same SSA value does not make the value live-IN.
        // Without this, a loop back-edge keeps body-local values
        // artificially alive around the whole loop and no death point
        // ever appears.
        var defined = std.DynamicBitSet.initEmpty(arena, ctx.n) catch unreachable;
        defer defined.deinit();
        for (blk.instrs) |ins| {
            if (std.meta.activeTag(ins.op) == .phi) {
                // A phi result is DEFINED in this block: a use after the
                // block-head phis is never upward-exposed, so the result
                // must enter `def_in`/`defined` exactly like any other
                // def. Without this the phi-input pass below cannot see
                // that an incoming was defined in its predecessor block
                // and marks it `use_in` there; liveness then propagates
                // the value up the CFG (past its real death point), and
                // the edge releases fire on unrelated edges — releasing
                // whatever lives in the slot then, e.g. a plain bool,
                // which the VM traps on (forged-pointer check).
                for (ins.results) |r| {
                    mark(ctx, &ctx.def_in[bi], r);
                    if (ctx.idx.get(r)) |ui| defined.set(ui);
                }
                continue; // operands are read on pred edges
            }
            try operandsOf(ctx.bld, ins, &ops);
            for (ops.items) |v| {
                if (ctx.idx.get(v)) |ui| {
                    ctx.used_anywhere[bi].set(ui);
                    if (!defined.isSet(ui)) ctx.use_in[bi].set(ui);
                }
            }
            ops.clearRetainingCapacity();
            for (ins.results) |r| {
                mark(ctx, &ctx.def_in[bi], r);
                if (ctx.idx.get(r)) |ui| defined.set(ui);
            }
        }
        // Terminator reads.
        switch (blk.terminator) {
            .ret => |rv| if (rv) |v| {
                try ops.append(arena, v);
            },
            .br => |b| {
                try ops.append(arena, b.cond);
            },
            .@"switch" => |s| try ops.append(arena, s.disc),
            .tailcall => |tc| try ops.appendSlice(arena, tc.args),
            .j, .trap => {},
        }
        // Terminator reads (`br.cond`, `switch.disc`) — the non-consuming
        // reads that must happen BEFORE any edge release (stage 7). `ret`
        // transfers the value out and `tailcall` consumes its args into
        // the window, so neither needs an edge release.
        switch (blk.terminator) {
            .br => |b| if (ctx.idx.get(b.cond)) |i| ctx.term_reads[bi].set(i),
            .@"switch" => |s| if (ctx.idx.get(s.disc)) |i| ctx.term_reads[bi].set(i),
            else => {},
        }
        for (ops.items) |v| mark(ctx, &ctx.used_anywhere[bi], v);
        for (ops.items) |v| {
            if (ctx.idx.get(v)) |ui| {
                if (!defined.isSet(ui)) ctx.use_in[bi].set(ui);
            }
        }
    }
    // Phi inputs: uses at the end of their predecessor block (always
    // exposed — they are read by the edge copies).
    for (ctx.f.blocks) |blk| {
        for (blk.instrs) |ins| switch (ins.op) {
            .phi => |p| for (p.incoming) |inc| {
                for (ctx.f.blocks, 0..) |pb, pbi| {
                    if (pb != inc.pred) continue;
                    mark(ctx, &ctx.used_anywhere[pbi], inc.value);
                    // Upward-exposed only: an input defined IN the pred
                    // block is read on the pred→succ edge, after the
                    // body — live at the end of the pred, not live-in
                    // of it. Marking it live-in would propagate it into
                    // the pred's own predecessors' `live_out` and
                    // release it on unrelated edges (an if-arm string
                    // released on the branch's *other* arm, into a slot
                    // that then holds a plain bool — forged-pointer
                    // trap). `used_anywhere` above still keeps it out
                    // of the dead-def release.
                    if (ctx.def_in[pbi].isSet(ctx.idx.get(inc.value) orelse continue)) continue;
                    mark(ctx, &ctx.use_in[pbi], inc.value);
                }
            },
            else => {},
        };
    }
}

/// Backward liveness fixpoint over the counted universe.
fn liveness(ctx: *FnCtx) error{OutOfMemory}!void {
    var changed = true;
    while (changed) {
        changed = false;
        for (ctx.f.blocks, 0..) |blk, bi| {
            // live_out = ∪ live_in(successors)
            var succs = std.ArrayList(*const cfg.BasicBlock).empty;
            defer succs.deinit(ctx.bld.arena);
            try successors(ctx.bld, blk, &succs);
            for (succs.items) |s| {
                const si = blockIndex(ctx.f, s) orelse continue;
                var it = ctx.live_in[si].iterator(.{});
                while (it.next()) |i| {
                    if (!ctx.live_out[bi].isSet(i)) {
                        ctx.live_out[bi].set(i);
                        changed = true;
                    }
                }
            }
            // live_in = use_in ∪ (live_out \ def_in)
            var it2 = ctx.live_out[bi].iterator(.{});
            while (it2.next()) |i| {
                if (ctx.def_in[bi].isSet(i)) continue;
                if (!ctx.live_in[bi].isSet(i)) {
                    ctx.live_in[bi].set(i);
                    changed = true;
                }
            }
            var it3 = ctx.use_in[bi].iterator(.{});
            while (it3.next()) |i| {
                if (!ctx.live_in[bi].isSet(i)) {
                    ctx.live_in[bi].set(i);
                    changed = true;
                }
            }
        }
    }
}

/// Place releases from the fixpoint sets:
/// - inside a death block (last body use, value not live-out): a
///   trailing record right after that instruction, unless the final
///   touch consumed the value;
/// - on an edge leaving the live region (`v ∈ live_out(p)` and
///   `v ∉ live_in(s)`), after the edge copies.
///
/// ponytail: a counted value whose ONLY remaining use is a terminator
/// read (a `switch` discriminant with no arm uses) cannot be released
/// after the jump — it leaks instead. Degenerate shape; revisit with a
/// pre-terminator release once the VM proves reading a tag after
/// release matters.
fn placeReleases(ctx: *FnCtx) error{OutOfMemory}!void {
    const arena = ctx.bld.arena;
    const bld = ctx.bld;
    for (ctx.f.blocks, 0..) |blk, bi| {
        // Per-value last body touch: instruction + consuming flag.
        var last_touch = try arena.alloc(?struct { ins: *cfg.Instr, consuming: bool }, ctx.n);
        @memset(last_touch, null);
        for (blk.instrs) |ins| {
            if (std.meta.activeTag(ins.op) == .phi) continue;
            var ops = std.ArrayList(*const cfg.Value).empty;
            defer ops.deinit(arena);
            try operandsOf(bld, ins, &ops);
            var cons = std.ArrayList(*const cfg.Value).empty;
            defer cons.deinit(arena);
            try consumedOf(bld, ins, &cons);
            for (ops.items) |v| {
                const i = ctx.idx.get(v) orelse continue;
                var consuming = false;
                for (cons.items) |cv| {
                    if (cv == v) consuming = true;
                }
                last_touch[i] = .{ .ins = ins, .consuming = consuming };
            }
        }
        // Dead defs: defined here and never read anywhere — release
        // right after the defining record so the object cannot leak.
        for (blk.instrs) |ins| {
            if (std.meta.activeTag(ins.op) == .phi) continue;
            for (ins.results) |r| {
                const i = ctx.idx.get(r) orelse continue;
                var used = false;
                for (ctx.used_anywhere) |bs| {
                    if (bs.isSet(i)) used = true;
                }
                if (!used) {
                    try appendTrailing(bld, ins, .{ .op = .release, .a = fitSlot(bld, r) });
                }
            }
        }
        // Death inside this block: any counted value whose final operand
        // touch is here and which is not live-out dies right after that
        // touch (born-and-dies-here values included — they need not be
        // live-in). A value read by this block's terminator is NOT
        // released here — the terminator reads the slot after the last
        // body touch, so the release must wait for the outgoing edges
        // (stage 7).
        for (last_touch, 0..) |t, i| {
            if (ctx.live_out[bi].isSet(i)) continue;
            const touch = t orelse continue; // terminator-only use: deferred to edges
            if (touch.consuming) continue; // moved/consumed — no release
            if (ctx.term_reads[bi].isSet(i)) continue; // terminator still reads it
            const v = valueAt(ctx, i) orelse continue;
            try appendTrailing(bld, touch.ins, .{ .op = .release, .a = fitSlot(bld, v) });
        }
        // Edge releases: candidates are `live_out` plus the
        // terminator-read set (a counted `switch` discriminant with no
        // arm uses is live only through the terminator, so it never
        // enters `live_out` — it must still release once on every
        // outgoing edge, after the read). Release on each DISTINCT
        // successor where the value is not live-in, excluding consuming
        // phi moves.
        var succs = std.ArrayList(*const cfg.BasicBlock).empty;
        defer succs.deinit(arena);
        try successors(bld, blk, &succs);
        var seen_succ = std.AutoHashMapUnmanaged(*const cfg.BasicBlock, void){};
        defer seen_succ.deinit(arena);
        for (succs.items) |s| {
            // A `switch` with repeated arms to one block must release
            // once, not once per arm.
            if (seen_succ.contains(s)) continue;
            try seen_succ.put(arena, s, {});
            const si = blockIndex(ctx.f, s) orelse continue;
            var eit = ctx.live_out[bi].iterator(.{});
            while (eit.next()) |i| {
                if (ctx.live_in[si].isSet(i)) continue;
                const v = valueAt(ctx, i) orelse continue;
                // A phi move on this edge consumes unique-counted sources;
                // an identity phi copy transfers by slot, not by release.
                if (edgeConsumes(blk, s, v)) continue;
                if (edgePhiIsSelfLoop(bld, blk, s, v)) continue;
                const gop = try bld.release_edges.getOrPut(arena, .{ .pred = blk, .succ = s });
                if (!gop.found_existing) gop.value_ptr.* = .empty;
                try gop.value_ptr.append(arena, .{ .op = .release, .a = fitSlot(bld, v) });
            }
            // Terminator-read candidates: a value read by the terminator
            // and not live-out anywhere here is dead after the terminator
            // on every outgoing edge.
            var tit = ctx.term_reads[bi].iterator(.{});
            while (tit.next()) |i| {
                if (ctx.live_out[bi].isSet(i)) continue; // handled above
                if (ctx.live_in[si].isSet(i)) continue; // survives into s
                const v = valueAt(ctx, i) orelse continue;
                if (edgeConsumes(blk, s, v)) continue;
                if (edgePhiIsSelfLoop(bld, blk, s, v)) continue;
                const gop = try bld.release_edges.getOrPut(arena, .{ .pred = blk, .succ = s });
                if (!gop.found_existing) gop.value_ptr.* = .empty;
                try gop.value_ptr.append(arena, .{ .op = .release, .a = fitSlot(bld, v) });
            }
        }
    }
}

/// Owners still alive at each tailcall terminator: `liveIn(b) ∩ owners`
/// minus values killed by the block's own consuming instructions. All
/// of them are destroyed after the `slot_*` preparation so the reused
/// frame starts with exactly the new parameters (spec §5.5).
fn planTailcallKills(ctx: *FnCtx) error{OutOfMemory}!void {
    const arena = ctx.bld.arena;
    const bld = ctx.bld;
    for (ctx.f.blocks) |blk| {
        const tc = switch (blk.terminator) {
            .tailcall => |t| t,
            else => continue,
        };
        _ = tc;
        var kills = std.ArrayList(Rec).empty;
        // Counted owners via the universe.
        if (ctx.n > 0) {
            const bi = blockIndex(ctx.f, blk).?;
            var killed = try std.DynamicBitSet.initEmpty(arena, ctx.n);
            defer killed.deinit();
            for (blk.instrs) |ins| {
                if (std.meta.activeTag(ins.op) == .phi) continue;
                var cons = std.ArrayList(*const cfg.Value).empty;
                defer cons.deinit(arena);
                try consumedOf(bld, ins, &cons);
                for (cons.items) |cv| {
                    if (ctx.idx.get(cv)) |i| killed.set(i);
                }
            }
            // Values already destroyed by the block's own trailing
            // releases (death inside this block, Instruction Set §4.3)
            // are gone from the registry before the slot prep — a
            // leftover kill would double-release them. Match by slot:
            // the trailing record targets the value's slot, and
            // `fitSlot` is the same slot identity the kill would use.
            for (blk.instrs) |ins| {
                if (std.meta.activeTag(ins.op) == .phi) continue;
                for (trailingOf(bld, ins)) |rec| {
                    if (rec.op != .release) continue;
                    var lit = ctx.live_in[bi].iterator(.{});
                    while (lit.next()) |i| {
                        const v = valueAt(ctx, i) orelse continue;
                        if (fitSlot(bld, v) == rec.a) killed.set(i);
                    }
                }
            }
            var it = ctx.live_in[bi].iterator(.{});
            while (it.next()) |i| {
                if (killed.isSet(i)) continue;
                const v = valueAt(ctx, i) orelse continue;
                try kills.append(arena, killRec(bld, v));
            }
        }
        // Unique owners (any/hostdata/opaque/deferred): forward scan of
        // what reaches this block is not tracked by the counted-only
        // universe, so walk the SSA definitions: a unique value defined
        // before this block and never consumed anywhere after its last
        // use... the frontend guarantees uniques are dropped/moved
        // before any terminator, EXCEPT move-mode parameters and
        // values whose consumption is the tailcall's own args. Those
        // were consumed by `slot_move` during preparation. So: emit
        // kills for unique-typed tailcall ARGUMENTS that were copied —
        // none: unique args always slot_move. Nothing extra to do for
        // uniques beyond the counted pass above; the validator's
        // unconsumed-owner check covers regressions.
        if (kills.items.len > 0) {
            try bld.tailcall_kills.put(arena, blk, kills);
        }
    }
}

/// The destroy record for one owner value: counted owners release;
/// unique owners would drop through their descriptor, but uniques are
/// always consumed by the frontend before any terminator — this helper
/// only ever sees counted values today.
fn killRec(bld: *Builder, v: *const cfg.Value) Rec {
    return .{ .op = .release, .a = fitSlot(bld, v) };
}

fn appendTrailing(bld: *Builder, ins: *const cfg.Instr, rec: Rec) error{OutOfMemory}!void {
    const gop = try bld.release_trailing.getOrPut(bld.arena, ins);
    if (!gop.found_existing) gop.value_ptr.* = .empty;
    try gop.value_ptr.append(bld.arena, rec);
}

fn fitSlot(bld: *Builder, v: *const cfg.Value) u32 {
    return bld.fit7(bld.slotOf(v));
}

fn blockIndex(f: *const cfg.IrFunc, blk: *const cfg.BasicBlock) ?usize {
    for (f.blocks, 0..) |b, i| {
        if (b == blk) return i;
    }
    return null;
}

fn valueAt(ctx: *FnCtx, i: usize) ?*const cfg.Value {
    var it = ctx.idx.iterator();
    while (it.next()) |e| {
        if (e.value_ptr.* == i) return e.key_ptr.*;
    }
    return null;
}

fn successors(bld: *Builder, blk: *const cfg.BasicBlock, out: *std.ArrayList(*const cfg.BasicBlock)) error{OutOfMemory}!void {
    switch (blk.terminator) {
        .j => |t| try out.append(bld.arena, t),
        .br => |b| {
            try out.append(bld.arena, b.then_);
            try out.append(bld.arena, b.else_);
        },
        .@"switch" => |s| for (s.arms) |arm| {
            try out.append(bld.arena, arm.block);
        },
        else => {},
    }
}

/// Whether the phi inputs on edge `pred → succ` consume `v` (a move of
/// a uniquely-owned source). Mirrors the opcode choice of
/// `edgeCopyList`: borrowed views install borrows, owned unique values
/// move, everything else copies.
fn edgeConsumes(pred: *const cfg.BasicBlock, succ: *const cfg.BasicBlock, v: *const cfg.Value) bool {
    for (succ.instrs) |ins| switch (ins.op) {
        .phi => |p| for (p.incoming) |inc| {
            if (inc.pred == pred and inc.value == v) {
                return v.state != .borrowed and v.ownership == .unique;
            }
        },
        else => {},
    };
    return false;
}

/// Whether `v`'s phi copy on edge `pred → succ` is an identity — the
/// phi result shares `v`'s slot, so the edge copy is elided and the
/// value flows through unchanged. Such a value must NOT be released on
/// the edge: the elided copy is the transfer, and releasing the slot
/// would destroy the reference the phi result owns (the unique path
/// skips through `edgeConsumes`; a counted self-loop flows through the
/// same way — `copy_retain` + release is only the non-identity form).
fn edgePhiIsSelfLoop(bld: *Builder, pred: *const cfg.BasicBlock, succ: *const cfg.BasicBlock, v: *const cfg.Value) bool {
    for (succ.instrs) |ins| switch (ins.op) {
        .phi => |p| for (p.incoming) |inc| {
            if (inc.pred == pred and inc.value == v) {
                return bld.slotOf(ins.results[0]) == bld.slotOf(v);
            }
        },
        else => {},
    };
    return false;
}

/// Whether this instruction consumes (transfers/destroys) `v`. Fixed
/// arities resolve through the schema's `consumes`; calls, syscalls,
/// and constructs resolve through signatures/types.
pub fn consumesValue(bld: *Builder, ins: *const cfg.Instr, v: *const cfg.Value) bool {
    var cons = std.ArrayList(*const cfg.Value).empty;
    defer cons.deinit(bld.arena);
    consumedOf(bld, ins, &cons) catch return false;
    for (cons.items) |cv| {
        if (cv == v) return true;
    }
    return false;
}

/// Collect the operands `ins` consumes, resolving signature-driven
/// consumption for the n-ary forms.
fn consumedOf(bld: *Builder, ins: *const cfg.Instr, out: *std.ArrayList(*const cfg.Value)) error{OutOfMemory}!void {
    const arena = bld.arena;
    const info = cfg.opInfo(std.meta.activeTag(ins.op));
    // Fixed-arity consumption by position.
    var fixed: [3]?*const cfg.Value = .{ null, null, null };
    var n_fixed: usize = 0;
    switch (ins.op) {
        .neg, .abs, .not_, .clz, .popcount, .num_cast, .any_pack_copy, .any_pack_move, .any_unpack_copy, .any_unpack_move, .copy, .borrow, .move_, .drop_, .tail, .unpack_struct, .unpack_tuple, .split_list, .read_tag, .read_payload, .cleanup_arm, .cleanup_disarm, .cleanup_drop => |v| {
            fixed[0] = v;
            n_fixed = 1;
        },
        .add, .sub, .mul, .div, .rem, .min, .max, .shl, .shr, .bitand, .bitor, .bitxor, .concat, .eq, .ne, .lt, .le, .gt, .ge => |b| {
            fixed[0] = b.a;
            fixed[1] = b.b;
            n_fixed = 2;
        },
        .select => |s| {
            fixed[0] = s.cond;
            fixed[1] = s.a;
            fixed[2] = s.b;
            n_fixed = 3;
        },
        else => {},
    }
    if (n_fixed > 0) {
        const c = info.consumes;
        if (c == .all) {
            for (fixed[0..n_fixed]) |fv| {
                if (fv) |x| try out.append(arena, x);
            }
        } else {
            if ((c == .op0 or c == .both) and n_fixed > 0) {
                if (fixed[0]) |x| try out.append(arena, x);
            }
            if ((c == .op1 or c == .both) and n_fixed > 1) {
                if (fixed[1]) |x| try out.append(arena, x);
            }
        }
        return;
    }
    switch (ins.op) {
        .construct => |c| for (c.args) |a| {
            if (a.ownership == .unique and a.state == .owned) try out.append(arena, a);
        },
        .call => |c| {
            const params = bld.calleeParamList(c.callee);
            for (c.args, 0..) |a, k| {
                const mode: ast.ParamMode = if (k < params.len) params[k].mode else .plain;
                if (mode == .move or (mode == .plain and a.ownership == .unique and a.state == .owned)) {
                    try out.append(arena, a);
                }
            }
        },
        .syscall => |sc| {
            const sig = sc.sig orelse return;
            for (sc.args, 0..) |a, k| {
                const mode: ast.ParamMode = if (k < sig.params.len) sig.params[k].mode else .plain;
                if (mode == .move or (mode == .plain and a.ownership == .unique and a.state == .owned)) {
                    try out.append(arena, a);
                }
            }
        },
        .phi => |p| for (p.incoming) |inc| {
            if (inc.value.state != .borrowed and inc.value.ownership == .unique) {
                try out.append(arena, inc.value);
            }
        },
        else => {},
    }
}

/// Collect the value operands of one instruction (exhaustive over the
/// CFG op set; n-ary forms enumerate their lists).
fn operandsOf(bld: *Builder, ins: *const cfg.Instr, out: *std.ArrayList(*const cfg.Value)) error{OutOfMemory}!void {
    const arena = bld.arena;
    switch (ins.op) {
        .const_, .module_ref, .fn_ref => {},
        .neg,
        .abs,
        .not_,
        .clz,
        .popcount,
        .num_cast,
        .any_pack_copy,
        .any_pack_move,
        .any_unpack_copy,
        .any_unpack_move,
        .copy,
        .borrow,
        .move_,
        .drop_,
        .tail,
        .unpack_struct,
        .unpack_tuple,
        .split_list,
        .read_tag,
        .read_payload,
        .cleanup_arm,
        .cleanup_disarm,
        .cleanup_drop,
        => |v| try out.append(arena, v),
        .type_is => |ti| try out.append(arena, ti.value),
        .load_member => |lm| try out.append(arena, lm.module),
        .store_member => |sm| try out.append(arena, sm.value),
        .read_field, .read_tuple => |pr| try out.append(arena, pr.base),
        .read_index => |ix| {
            try out.append(arena, ix.base);
            try out.append(arena, ix.index);
        },
        .unpack_variant => |uv| try out.append(arena, uv.base),
        .borrow_variant => |bv| try out.append(arena, bv.base),
        .select => |sl| {
            try out.append(arena, sl.cond);
            try out.append(arena, sl.a);
            try out.append(arena, sl.b);
        },
        .add,
        .sub,
        .mul,
        .div,
        .rem,
        .min,
        .max,
        .shl,
        .shr,
        .bitand,
        .bitor,
        .bitxor,
        .concat,
        .eq,
        .ne,
        .lt,
        .le,
        .gt,
        .ge,
        => |b| {
            try out.append(arena, b.a);
            try out.append(arena, b.b);
        },
        .construct => |c| try out.appendSlice(arena, c.args),
        .call => |c| try out.appendSlice(arena, c.args),
        .syscall => |sc| try out.appendSlice(arena, sc.args),
        .phi => |p| for (p.incoming) |inc| {
            try out.append(arena, inc.value);
        },
    }
}
