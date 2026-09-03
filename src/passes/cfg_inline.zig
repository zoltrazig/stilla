//! Pass: function inlining (optimizer.md, Pass 8 — first sub-pass).
//! In: a lowered `cfg.IrProgram` (after tail-call elimination, Pass 7).
//! Out: the same program, with selected direct calls replaced by a spliced
//! copy of the callee's body: parameters are bound at the splice point
//! (renamed to the call's arguments), the callee's `ret` blocks are
//! re-wired to the call's continuation, and the call's result is rebound
//! as the continuation's return phi.
//!
//! Runs as the first sub-pass of `cfg_optimize.zig` (after `tailCall`,
//! before `cse`) — so `cse`/`copyProp`/`pre`/`deadInstr` clean the
//! duplicated redundancy, `dropElide`/drop lowering see the new drops,
//! and `phiSimplify`/`jumpThread` clean the new blocks; never in the
//! LLIR projection, which is a read-only view of the validated CFG.
//!
//! ## Candidate rules
//!
//! ### Safety — hard filters
//!
//! 1. Direct call to a statically known `IrFunc` only (no function
//!    values, same as TCO, air.md §14.7).
//! 2. Non-recursive: the candidate's call-graph path must not reach the
//!    enclosing function (reject self- and mutual recursion; build the
//!    call graph once up front).
//! 3. Call-site arguments 1:1 with the callee's parameters. A void-typed
//!    parameter produces no call operand (phase3-cfg-lowering.md,
//!    Lowering rules), so such a callee is skipped rather than bound to
//!    an invented value.
//! 4. The callee's body must contain no `tailcall` terminator (a
//!    frame-reusing self-call is specific to the callee's frame and
//!    meaningless inside the caller) and no `store_member` (valid only
//!    inside `@init`, air.md §5.6). A call that defines a result requires
//!    the callee to have at least one `ret` block — a never-returning
//!    callee never produces the result, so its call is left alone.
//!
//! **Ownership is NOT a filter.** Unlike TCO (Copy-only because of frame
//! reuse + move-mode params looping through phis, air.md §14.7), inlining
//! binds each parameter exactly once and executes the body exactly once.
//! The splice renames each parameter to its call-site argument — a
//! consumed argument may not be reused anyway, and the callee consumes it
//! at exactly the points the `call` did — so the resulting ownership
//! dataflow is pointwise equivalent to the original `call`, and the
//! air.md §13 validator backstops it.
//!
//! ### Cost model
//!
//! Candidate if `calleeCost < inline_budget` (25). `calleeCost` sums
//! `instrCost` over the body (terminators excluded — the splice re-wires
//! them): simple ops cost 1, complex ops cost 5.
//!
//! - simple (1): total register/SSA ops — constants, module/fn refs,
//!   comparisons, `not`/`neg`/`num_cast`/`type_is`, int `add`/`sub`/`mul`,
//!   `copy`/`borrow`/`move`, pure projections (`load_member`,
//!   `read_field`, `read_tuple`, `read_tag`, `read_payload`, `tail`),
//!   `phi`;
//! - complex (5): everything else — ops that may trap (`div`, `rem`,
//!   `read_index`, `any_unpack_*`), allocate (`concat`, `construct`,
//!   `any_pack_*`), call (`call`, `syscall`), destroy (`drop`,
//!   `cleanup_*`, `store_member`), or are multi-result destructures
//!   (`unpack_*`, `split_list`, `borrow_variant`).
//!
//! Bonuses/penalties on the effective budget are TODO heuristics: single
//! call site (any size — no duplication), leaf callee, tail-position
//! call site, call site in a loop raise it; many call sites and a large
//! caller lower it. Tune `inline_budget` and the lists on the corpus via
//! the optimization harness before shipping.
//!
//! ## The splice
//!
//! A call `%r = call @g, %a…` in block `b` is replaced by:
//!
//! - `b` keeps the instructions before the call and becomes the prefix,
//!   branching to the cloned callee entry;
//! - a fresh continuation block `cont` receives the instructions after
//!   the call and the original terminator;
//! - the callee's blocks are cloned into `f` (fresh ids, names, values;
//!   every operand, origin root, and edge rewritten through the maps);
//! - each cloned `ret` block jumps to `cont`; when the call defines a
//!   result, `cont` opens with a return phi joining the cloned return
//!   values — the phi result *is* the call's result value, whose `def`
//!   moves to the phi, so no use-site rewriting is needed (borrowed views
//!   rooted at the result stay correct);
//! - every old successor of `b` replaces `b` with `cont` in its
//!   predecessor list and phi incomings.
//!
//! Parameters are renamed to the call's arguments (the callee's borrow
//! views then root at the caller's values, so cloned `origin.root`
//! pointers are rewritten through the value map). The eligibility check
//! rejects arity mismatches, so the parameter list maps 1:1 onto the
//! argument list.

const std = @import("std");
const cfg = @import("stilla").cfg;

/// Inline cost threshold: a candidate callee inlines only when
/// `calleeCost(f) < inline_budget`.
pub const inline_budget: u32 = 25;

/// Per-op inline cost: 1 for cheap total register/SSA ops, 5 for
/// anything that may trap, allocate, call, destroy, or is
/// n-ary/multi-result. Tune on the corpus (see file doc).
fn instrCost(tag: cfg.OpTag) u32 {
    return switch (tag) {
        .const_,
        .module_ref,
        .fn_ref,
        .neg,
        .not_,
        .num_cast,
        .type_is,
        .add,
        .sub,
        .mul,
        .eq,
        .ne,
        .lt,
        .le,
        .gt,
        .ge,
        .copy,
        .borrow,
        .move_,
        .load_member,
        .read_field,
        .read_tuple,
        .read_tag,
        .read_payload,
        .tail,
        .phi,
        => 1,
        else => 5,
    };
}

/// Body cost of a candidate callee: sum of per-instruction costs over
/// all blocks. Terminators are excluded — the splice re-wires them.
pub fn calleeCost(f: *const cfg.IrFunc) u32 {
    var total: u32 = 0;
    for (f.blocks) |b| {
        for (b.instrs) |instr| {
            total += instrCost(std.meta.activeTag(instr.op));
        }
    }
    return total;
}

/// Direct-call adjacency: function → its direct callees (resolved `call`
/// targets plus `tailcall` targets). Built once up front; the recursion
/// guard walks it per candidate.
const CallGraph = struct {
    map: std.AutoHashMap(*const cfg.IrFunc, std.ArrayList(*const cfg.IrFunc)),

    fn init(allocator: std.mem.Allocator) CallGraph {
        return .{ .map = std.AutoHashMap(*const cfg.IrFunc, std.ArrayList(*const cfg.IrFunc)).init(allocator) };
    }

    fn deinit(self: *CallGraph) void {
        var it = self.map.valueIterator();
        while (it.next()) |list| list.deinit(self.map.allocator);
        self.map.deinit();
    }

    fn add(self: *CallGraph, from: *const cfg.IrFunc, to: *const cfg.IrFunc, allocator: std.mem.Allocator) !void {
        const gop = try self.map.getOrPut(from);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(allocator, to);
    }

    /// True when `from` can reach `to` through direct calls (a self-call
    /// reaches the enclosing function directly).
    fn reaches(self: *const CallGraph, from: *const cfg.IrFunc, to: *const cfg.IrFunc, allocator: std.mem.Allocator) !bool {
        if (from == to) return true;
        var stack = std.ArrayList(*const cfg.IrFunc).empty;
        defer stack.deinit(allocator);
        var visited = std.AutoHashMap(*const cfg.IrFunc, void).init(allocator);
        defer visited.deinit();
        try stack.append(allocator, from);
        while (stack.pop()) |cur| {
            if (visited.contains(cur)) continue;
            try visited.put(cur, {});
            const callees = self.map.get(cur) orelse continue;
            for (callees.items) |c| {
                if (c == to) return true;
                try stack.append(allocator, c);
            }
        }
        return false;
    }
};

/// Rewrite every direct call in `program` to an eligible callee into a
/// spliced copy of the callee's body, once per call site (no fixpoint —
/// the spliced body's own calls are left for a later visit of the
/// callee's own copy). The air.md §13 validator backstops each rewrite
/// (the driver runs it after this pass).
pub fn inlineCalls(program: *cfg.IrProgram, allocator: std.mem.Allocator) !void {
    // The frontend's lowered CFG leaves `Call.callee.direct.func` null
    // until resolved; a direct call is a candidate only against a known
    // IrFunc, so resolve first. Idempotent: already-resolved calls are
    // skipped.
    try program.resolveDirectCalls(allocator);
    var graph = CallGraph.init(allocator);
    defer graph.deinit();
    for (program.funcs) |f| {
        for (f.blocks) |b| {
            for (b.instrs) |instr| {
                if (instr.op == .call and instr.op.call.callee == .direct) {
                    if (instr.op.call.callee.direct.func) |g| try graph.add(f, g, allocator);
                }
            }
            if (b.terminator == .tailcall) {
                if (b.terminator.tailcall.func) |g| try graph.add(f, g, allocator);
            }
        }
    }
    for (program.funcs) |f| {
        try inlineInto(f, &graph, allocator);
    }
}

/// One eligible call site: the call instruction and its callee.
const Site = struct {
    instr: *cfg.Instr,
    callee: *cfg.IrFunc,
};

/// Inline every eligible call site in the original blocks of `f` (a
/// snapshot — the spliced body's own call sites are not re-scanned this
/// round, keeping the pass one shot). Within a block the rightmost
/// eligible call is processed first, so splitting the block moves only
/// already-processed (or ineligible) calls into the continuation.
fn inlineInto(f: *cfg.IrFunc, graph: *const CallGraph, allocator: std.mem.Allocator) !void {
    const blocks = try allocator.dupe(*cfg.BasicBlock, f.blocks);
    defer allocator.free(blocks);
    var next_block: u32 = 0;
    var next_value: u32 = 0;
    for (f.blocks) |b| next_block = @max(next_block, b.id);
    for (f.values) |v| next_value = @max(next_value, v.id);
    var any = false;
    for (blocks) |b| {
        while (try findEligible(f, b, graph, allocator)) |site| {
            try splice(f, b, site.instr, site.callee, allocator, &next_block, &next_value);
            any = true;
        }
    }
    // The block list is in creation order, but the printer emits blocks
    // in smallest-value-id order (cfg.BlockOrder) — a continuation whose
    // post-call code uses a nested clone's values would otherwise print
    // before those clones, a forward reference the text form rejects
    // (air.md §13). Renumber in a def-before-use order instead.
    if (any) try renumberPrintOrder(f, allocator);
}

/// The rightmost eligible call in `b`'s current instructions; null when
/// none remain.
fn findEligible(f: *cfg.IrFunc, b: *cfg.BasicBlock, graph: *const CallGraph, allocator: std.mem.Allocator) !?Site {
    var i = b.instrs.len;
    while (i > 0) {
        i -= 1;
        const instr = b.instrs[i];
        if (instr.op != .call) continue;
        const c = instr.op.call;
        if (c.callee != .direct) continue;
        const g = c.callee.direct.func orelse continue;
        if (!try eligible(f, g, instr, graph, allocator)) continue;
        return .{ .instr = instr, .callee = g };
    }
    return null;
}

/// The candidate hard filters (see file doc).
fn eligible(f: *cfg.IrFunc, g: *cfg.IrFunc, instr: *const cfg.Instr, graph: *const CallGraph, allocator: std.mem.Allocator) !bool {
    // 1:1 args/params — a void-typed parameter produces no call operand,
    // so a mismatch means the callee has a void parameter and is skipped.
    if (instr.op.call.args.len != g.params.len) return false;
    if (calleeCost(g) >= inline_budget) return false;
    if (instr.results.len > 0) {
        var has_ret = false;
        for (g.blocks) |gb| {
            if (gb.terminator == .ret) {
                has_ret = true;
                break;
            }
        }
        if (!has_ret) return false; // the call never completes; no result
    }
    for (g.blocks) |gb| {
        if (gb.terminator == .tailcall) return false; // caller-frame-specific
        for (gb.instrs) |gi| {
            if (gi.op == .store_member) return false; // @init-only (air.md §5.6)
        }
    }
    return !(try graph.reaches(g, f, allocator));
}

/// Replace `%r = call @g, %a…` (in `call_block`) by the spliced callee
/// body: the block becomes the prefix branching to the cloned entry, a
/// fresh continuation holds the return phi (reusing `%r`) plus the
/// instructions after the call and the original terminator, and the
/// cloned `ret` blocks jump to it. `next_block` / `next_value` track the
/// per-function id counters across sites.
fn splice(
    f: *cfg.IrFunc,
    call_block: *cfg.BasicBlock,
    call_instr: *cfg.Instr,
    g: *cfg.IrFunc,
    allocator: std.mem.Allocator,
    next_block: *u32,
    next_value: *u32,
) !void {
    const args = call_instr.op.call.args;
    const call_result: ?*cfg.Value = if (call_instr.results.len > 0) call_instr.results[0] else null;
    const old_term = call_block.terminator;

    // Split the block's instructions: the prefix keeps everything before
    // the call; the continuation takes everything after it.
    var prefix = std.ArrayList(*cfg.Instr).empty;
    var post = std.ArrayList(*cfg.Instr).empty;
    var after = false;
    for (call_block.instrs) |instr| {
        if (instr == call_instr) {
            after = true;
        } else if (after) {
            try post.append(allocator, instr);
        } else {
            try prefix.append(allocator, instr);
        }
    }

    // Clone the callee's blocks first (fresh ids and unique names), so
    // every cloned edge can resolve through the block map.
    var block_map = std.AutoHashMap(*cfg.BasicBlock, *cfg.BasicBlock).init(allocator);
    defer block_map.deinit();
    const clones = try allocator.alloc(*cfg.BasicBlock, g.blocks.len);
    defer allocator.free(clones);
    for (g.blocks, 0..) |gb, i| {
        next_block.* += 1;
        const c = try allocator.create(cfg.BasicBlock);
        c.* = .{
            .id = next_block.*,
            .span = gb.span,
            .name = try uniqueName(f, clones[0..i], gb.name, allocator),
            .instrs = &.{},
            .terminator = .trap, // rewritten in the clone pass
            .preds = &.{},
        };
        clones[i] = c;
        try block_map.put(gb, c);
    }
    const entry_clone = block_map.get(g.entry).?;

    // The callee's block print order: the clones' value ids follow it, so
    // the cloned body preserves the callee's use-before-def text ordering
    // (air.md §13) — creation order differs for a match's arm blocks, which
    // print after their test chain.
    const g_order = try allocator.alloc(*cfg.BasicBlock, g.blocks.len);
    defer allocator.free(g_order);
    for (g.blocks, 0..) |gb, i| g_order[i] = gb;
    std.mem.sort(*cfg.BasicBlock, g_order, cfg.BlockOrder{ .entry = g.entry }, cfg.BlockOrder.lessThan);

    // Bind the parameters to the call's arguments and preallocate a
    // fresh value per callee instruction result, before any instruction
    // is cloned (phi incomings and borrow origins may reference values
    // from blocks cloned later).
    var value_map = std.AutoHashMap(*cfg.Value, *cfg.Value).init(allocator);
    defer value_map.deinit();
    for (g.params, 0..) |_, i| try value_map.put(g.values[i], args[i]);
    for (g_order) |gb| {
        for (gb.instrs) |gi| {
            for (gi.results) |v| {
                next_value.* += 1;
                const nv = try allocator.create(cfg.Value);
                nv.* = .{
                    .id = next_value.*,
                    .span = v.span,
                    .type_ = v.type_,
                    .ownership = v.ownership,
                    .state = v.state,
                    .origin = mapOrigin(v.origin, &value_map),
                    .def = null, // filled once the cloned instruction exists
                };
                try value_map.put(v, nv);
            }
        }
    }

    // The continuation: the call's post-instructions plus the original
    // terminator. Its head phi and predecessor list are filled below,
    // once the cloned return blocks are known.
    next_block.* += 1;
    const cont = try allocator.create(cfg.BasicBlock);
    cont.* = .{
        .id = next_block.*,
        .span = call_block.span,
        .name = try uniqueName(f, clones, "inline_join", allocator),
        .instrs = &.{},
        .terminator = old_term,
        .preds = &.{},
    };

    // Clone instructions and terminators. A cloned `ret` becomes a jump
    // to the continuation, recorded as a return block.
    var ret_clones = std.ArrayList(*cfg.BasicBlock).empty;
    var ret_values = std.ArrayList(?*cfg.Value).empty;
    for (g.blocks, 0..) |gb, i| {
        const c = clones[i];
        var instrs = std.ArrayList(*cfg.Instr).empty;
        for (gb.instrs) |gi| {
            const ci = try allocator.create(cfg.Instr);
            ci.* = .{
                .span = gi.span,
                .results = try cloneResults(gi.results, &value_map, allocator),
                .op = try cloneOp(gi.op, &value_map, &block_map, allocator),
                .synth = gi.synth,
            };
            for (ci.results) |rv| rv.def = ci;
            try instrs.append(allocator, ci);
        }
        c.instrs = try instrs.toOwnedSlice(allocator);
        switch (gb.terminator) {
            .ret => |v| {
                c.terminator = .{ .j = cont };
                try ret_clones.append(allocator, c);
                try ret_values.append(allocator, if (v) |val| value_map.get(val) else null);
            },
            .j => |t| c.terminator = .{ .j = block_map.get(t).? },
            .br => |bc| c.terminator = .{ .br = .{ .cond = value_map.get(bc.cond).?, .then_ = block_map.get(bc.then_).?, .else_ = block_map.get(bc.else_).? } },
            .@"switch" => |s| {
                const arms = try allocator.alloc(cfg.SwitchArm, s.arms.len);
                for (s.arms, 0..) |arm, j| arms[j] = .{ .tag = arm.tag, .block = block_map.get(arm.block).? };
                c.terminator = .{ .@"switch" = .{ .disc = value_map.get(s.disc).?, .arms = arms } };
            },
            .tailcall => unreachable, // rejected by the eligibility check
            .trap => c.terminator = .trap,
        }
        var preds = std.ArrayList(*cfg.BasicBlock).empty;
        for (gb.preds) |p| try preds.append(allocator, block_map.get(p).?);
        c.preds = try preds.toOwnedSlice(allocator);
    }
    // The cloned entry's only predecessor is the call block (the callee's
    // entry had none).
    entry_clone.preds = try allocator.dupe(*cfg.BasicBlock, &.{call_block});

    // The continuation's predecessors are the cloned return blocks; a
    // result call opens it with the return phi — its result *is* the
    // call's result value, whose definition moves to the phi.
    cont.preds = try allocator.dupe(*cfg.BasicBlock, ret_clones.items);
    if (call_result) |cr| {
        const incoming = try allocator.alloc(cfg.PhiIn, ret_clones.items.len);
        for (ret_clones.items, 0..) |rc, i| {
            // A result-call callee is validated, so every return block
            // returns a value of the callee's return type.
            incoming[i] = .{ .value = ret_values.items[i].?, .pred = rc };
        }
        const results = try allocator.alloc(*cfg.Value, 1);
        results[0] = cr;
        const phi = try allocator.create(cfg.Instr);
        phi.* = .{
            .span = call_instr.span,
            .results = results,
            .op = .{ .phi = .{ .incoming = incoming } },
        };
        cr.def = phi;
        const combined = try allocator.alloc(*cfg.Instr, 1 + post.items.len);
        combined[0] = phi;
        @memcpy(combined[1..], post.items);
        cont.instrs = combined;
    } else {
        cont.instrs = try post.toOwnedSlice(allocator);
    }

    // The call block becomes the prefix, branching into the cloned entry.
    call_block.instrs = try prefix.toOwnedSlice(allocator);
    call_block.terminator = .{ .j = entry_clone };

    // Every old successor replaces the call block with the continuation
    // in its predecessor list and phi incomings (in place, order kept —
    // a self-target, a `br` with equal arms, or a shared `switch` target
    // is rewritten per occurrence).
    switch (old_term) {
        .j => |t| rewireTarget(t, call_block, cont),
        .br => |bc| {
            rewireTarget(bc.then_, call_block, cont);
            rewireTarget(bc.else_, call_block, cont);
        },
        .@"switch" => |s| for (s.arms) |arm| rewireTarget(arm.block, call_block, cont),
        .ret, .tailcall, .trap => {},
    }

    var all_blocks = std.ArrayList(*cfg.BasicBlock).empty;
    try all_blocks.appendSlice(allocator, f.blocks);
    try all_blocks.appendSlice(allocator, clones);
    try all_blocks.append(allocator, cont);
    f.blocks = try all_blocks.toOwnedSlice(allocator);
}

/// Replace `from` with `to` in `t`'s predecessor list and in every phi
/// incoming of `t` whose predecessor is `from`.
fn rewireTarget(t: *cfg.BasicBlock, from: *cfg.BasicBlock, to: *cfg.BasicBlock) void {
    for (t.preds) |*p| {
        if (p.* == from) p.* = to;
    }
    for (t.instrs) |instr| {
        if (instr.op != .phi) continue;
        for (instr.op.phi.incoming) |*inc| {
            if (inc.pred == from) inc.pred = to;
        }
    }
}

/// The fresh values for a cloned instruction's results.
fn cloneResults(results: []*cfg.Value, value_map: *const std.AutoHashMap(*cfg.Value, *cfg.Value), allocator: std.mem.Allocator) ![]*cfg.Value {
    const out = try allocator.alloc(*cfg.Value, results.len);
    for (results, 0..) |v, i| out[i] = value_map.get(v).?;
    return out;
}

/// Clone an operation: every value operand through the value map, every
/// block edge through the block map, and every mutable operand slice
/// (construct/call/syscall args, phi incomings) freshly allocated — never
/// shared with the original callee.
fn cloneOp(
    op: cfg.Op,
    value_map: *const std.AutoHashMap(*cfg.Value, *cfg.Value),
    block_map: *const std.AutoHashMap(*cfg.BasicBlock, *cfg.BasicBlock),
    allocator: std.mem.Allocator,
) !cfg.Op {
    var out = op;
    switch (out) {
        .neg, .abs, .clz, .popcount, .not_, .num_cast, .any_pack_copy, .any_pack_move, .any_unpack_copy, .any_unpack_move, .cleanup_arm, .cleanup_disarm, .cleanup_drop, .copy, .borrow, .move_, .tail, .unpack_struct, .unpack_tuple, .split_list, .read_tag, .read_payload, .drop_ => |*v| {
            v.* = value_map.get(v.*).?;
        },
        .unpack_variant => |*x| x.base = value_map.get(x.base).?,
        .borrow_variant => |*x| x.base = value_map.get(x.base).?,
        .type_is => |*x| x.value = value_map.get(x.value).?,
        .add, .sub, .mul, .div, .rem, .min, .max, .shl, .shr, .bitand, .bitor, .bitxor, .concat, .eq, .ne, .lt, .le, .gt, .ge => |*x| {
            x.a = value_map.get(x.a).?;
            x.b = value_map.get(x.b).?;
        },
        .select => |*x| {
            x.cond = value_map.get(x.cond).?;
            x.a = value_map.get(x.a).?;
            x.b = value_map.get(x.b).?;
        },
        .load_member => |*x| x.module = value_map.get(x.module).?,
        .store_member => |*x| x.value = value_map.get(x.value).?,
        .construct => |*c| {
            const mapped = try allocator.alloc(*cfg.Value, c.args.len);
            for (c.args, 0..) |a, i| mapped[i] = value_map.get(a).?;
            c.args = mapped;
        },
        .read_field, .read_tuple => |*x| x.base = value_map.get(x.base).?,
        .read_index => |*x| {
            x.base = value_map.get(x.base).?;
            x.index = value_map.get(x.index).?;
        },
        .call => |*c| {
            if (c.callee == .value) c.callee.value = value_map.get(c.callee.value).?;
            const mapped = try allocator.alloc(*cfg.Value, c.args.len);
            for (c.args, 0..) |a, i| mapped[i] = value_map.get(a).?;
            c.args = mapped;
        },
        .syscall => |*s| {
            const mapped = try allocator.alloc(*cfg.Value, s.args.len);
            for (s.args, 0..) |a, i| mapped[i] = value_map.get(a).?;
            s.args = mapped;
        },
        .phi => |*p| {
            const incoming = try allocator.alloc(cfg.PhiIn, p.incoming.len);
            for (p.incoming, 0..) |inc, i| {
                incoming[i] = .{ .value = value_map.get(inc.value).?, .pred = block_map.get(inc.pred).? };
            }
            p.incoming = incoming;
        },
        .const_, .module_ref, .fn_ref => {},
    }
    return out;
}

/// Rewrite a borrow origin's root through the value map. A `.call` origin
/// only ever sits on a borrow-mode parameter, which the splice renames
/// away, so no cloned value carries one.
fn mapOrigin(origin: ?cfg.BorrowOrigin, value_map: *const std.AutoHashMap(*cfg.Value, *cfg.Value)) ?cfg.BorrowOrigin {
    const o = origin orelse return null;
    return switch (o) {
        .root => |base| .{ .root = value_map.get(base) orelse base },
        .call => o,
    };
}

/// Assign fresh value ids in a def-before-use order, so the printed text
/// (blocks in `cfg.BlockOrder` — smallest value id first) is valid SSA
/// text (air.md §13): repeatedly emit the first block whose non-phi
/// instruction and terminator operands are all defined in already-emitted
/// blocks or in the block itself (only phi incomings may
/// forward-reference — a loop back edge). This is a stable topological
/// order of the use-dependency graph; the block list itself is left in
/// creation order.
///
/// The rewrite passes (copyProp, phiSimplify) substitute values across
/// blocks and `cfg.renumberValues` preserves the pre-existing relative
/// print order, so a substitution can leave a forward reference (e.g.
/// phiSimplify folding a single-incoming return phi into a use in the
/// inliner's continuation). The optimizer driver re-runs this at the end
/// of the pass sequence to restore the invariant.
pub fn renumberPrintOrder(f: *cfg.IrFunc, allocator: std.mem.Allocator) !void {
    const n = f.blocks.len;
    const emitted = try allocator.alloc(bool, n);
    defer allocator.free(emitted);
    @memset(emitted, false);

    // value → index of the block that defines it (parameters have no def
    // block and are always emitted first).
    var def_block = std.AutoHashMap(*cfg.Value, u32).init(allocator);
    defer def_block.deinit();
    for (f.blocks, 0..) |b, i| {
        for (b.instrs) |instr| for (instr.results) |v| try def_block.put(v, @intCast(i));
    }

    var order = try allocator.alloc(*cfg.BasicBlock, n);
    defer allocator.free(order);
    var emitted_count: usize = 0;
    while (emitted_count < n) {
        var chosen: ?u32 = null;
        for (f.blocks, 0..) |b, i| {
            if (emitted[i]) continue;
            if (operandsEmitted(b, @intCast(i), &def_block, emitted)) {
                chosen = @intCast(i);
                break;
            }
        }
        if (chosen == null) {
            for (f.blocks, 0..) |_, i| {
                if (!emitted[i]) {
                    chosen = @intCast(i);
                    break;
                }
            }
        }
        const ci = chosen.?;
        emitted[ci] = true;
        order[emitted_count] = f.blocks[ci];
        emitted_count += 1;
    }

    var values = std.ArrayList(*cfg.Value).empty;
    for (f.values[0..f.params.len]) |v| try values.append(allocator, v);
    var next: u32 = @intCast(f.params.len);
    for (order) |b| {
        for (b.instrs) |instr| {
            for (instr.results) |v| {
                v.id = next;
                next += 1;
                try values.append(allocator, v);
            }
        }
    }
    f.values = try values.toOwnedSlice(allocator);
}

/// Every non-phi instruction operand of `b` — and every terminator operand
/// — is defined in an emitted block or in `b` itself (defs earlier in the
/// same block print first). Terminator operands (`br` cond, `switch` disc,
/// `ret` value, `tailcall` args) must hold too: the AIR text grammar lets
/// only phi incomings reference a value defined later in the text (a loop
/// back edge), so a cond printed before its definition would not re-parse.
fn operandsEmitted(b: *const cfg.BasicBlock, own: u32, def_block: *const std.AutoHashMap(*cfg.Value, u32), emitted: []const bool) bool {
    for (b.instrs) |instr| {
        if (instr.op == .phi) continue;
        if (!opOperandsEmitted(instr.op, own, def_block, emitted)) return false;
    }
    return terminatorOperandsEmitted(b.terminator, own, def_block, emitted);
}

fn terminatorOperandsEmitted(t: cfg.Terminator, own: u32, def_block: *const std.AutoHashMap(*cfg.Value, u32), emitted: []const bool) bool {
    return switch (t) {
        .ret => |v| if (v) |value| valueEmitted(value, own, def_block, emitted) else true,
        .j, .trap => true,
        .br => |x| valueEmitted(x.cond, own, def_block, emitted),
        .@"switch" => |x| valueEmitted(x.disc, own, def_block, emitted),
        .tailcall => |x| argsEmitted(x.args, own, def_block, emitted),
    };
}

fn opOperandsEmitted(op: cfg.Op, own: u32, def_block: *const std.AutoHashMap(*cfg.Value, u32), emitted: []const bool) bool {
    return switch (op) {
        .neg, .abs, .clz, .popcount, .not_, .num_cast, .any_pack_copy, .any_pack_move, .any_unpack_copy, .any_unpack_move, .cleanup_arm, .cleanup_disarm, .cleanup_drop, .copy, .borrow, .move_, .tail, .unpack_struct, .unpack_tuple, .split_list, .read_tag, .read_payload, .drop_ => |v| valueEmitted(v, own, def_block, emitted),
        .unpack_variant => |x| valueEmitted(x.base, own, def_block, emitted),
        .borrow_variant => |x| valueEmitted(x.base, own, def_block, emitted),
        .read_field => |x| valueEmitted(x.base, own, def_block, emitted),
        .read_tuple => |x| valueEmitted(x.base, own, def_block, emitted),
        .type_is => |x| valueEmitted(x.value, own, def_block, emitted),
        .add, .sub, .mul, .div, .rem, .min, .max, .shl, .shr, .bitand, .bitor, .bitxor, .concat, .eq, .ne, .lt, .le, .gt, .ge => |x| valueEmitted(x.a, own, def_block, emitted) and valueEmitted(x.b, own, def_block, emitted),
        .select => |x| valueEmitted(x.cond, own, def_block, emitted) and valueEmitted(x.a, own, def_block, emitted) and valueEmitted(x.b, own, def_block, emitted),
        .load_member => |x| valueEmitted(x.module, own, def_block, emitted),
        .store_member => |x| valueEmitted(x.value, own, def_block, emitted),
        .construct => |x| argsEmitted(x.args, own, def_block, emitted),
        .syscall => |x| argsEmitted(x.args, own, def_block, emitted),
        .call => |x| switch (x.callee) {
            .value => |cv| valueEmitted(cv, own, def_block, emitted) and argsEmitted(x.args, own, def_block, emitted),
            .direct => argsEmitted(x.args, own, def_block, emitted),
        },
        .read_index => |x| valueEmitted(x.base, own, def_block, emitted) and valueEmitted(x.index, own, def_block, emitted),
        .phi, .const_, .module_ref, .fn_ref => true,
    };
}

fn argsEmitted(args: []*cfg.Value, own: u32, def_block: *const std.AutoHashMap(*cfg.Value, u32), emitted: []const bool) bool {
    for (args) |a| {
        if (!valueEmitted(a, own, def_block, emitted)) return false;
    }
    return true;
}

fn valueEmitted(v: *cfg.Value, own: u32, def_block: *const std.AutoHashMap(*cfg.Value, u32), emitted: []const bool) bool {
    const bi = def_block.get(v) orelse return true; // parameters
    if (bi == own) return true; // defined earlier in the same block
    return emitted[bi];
}

/// A block name not already used in `f` (or claimed by the clones created
/// so far in the current splice — the clone list is only attached to
/// `f.blocks` at the end of the splice, so `f.blocks` alone would miss
/// same-splice collisions, air.md §13).
fn uniqueName(f: *cfg.IrFunc, claimed: []const *cfg.BasicBlock, base: []const u8, allocator: std.mem.Allocator) ![]const u8 {
    var n: u32 = 0;
    while (true) {
        const candidate = if (n == 0) base else try std.fmt.allocPrint(allocator, "{s}_{d}", .{ base, n });
        var taken = false;
        for (f.blocks) |b| {
            if (std.mem.eql(u8, b.name, candidate)) {
                taken = true;
                break;
            }
        }
        if (!taken) {
            for (claimed) |b| {
                if (std.mem.eql(u8, b.name, candidate)) {
                    taken = true;
                    break;
                }
            }
        }
        if (!taken) return candidate;
        n += 1;
    }
}

test "inline cost: simple ops cost 1, complex ops cost 5" {
    try std.testing.expectEqual(@as(u32, 1), instrCost(.const_));
    try std.testing.expectEqual(@as(u32, 1), instrCost(.add));
    try std.testing.expectEqual(@as(u32, 1), instrCost(.read_field));
    try std.testing.expectEqual(@as(u32, 1), instrCost(.phi));
    try std.testing.expectEqual(@as(u32, 5), instrCost(.div));
    try std.testing.expectEqual(@as(u32, 5), instrCost(.concat));
    try std.testing.expectEqual(@as(u32, 5), instrCost(.call));
    try std.testing.expectEqual(@as(u32, 5), instrCost(.drop_));
    try std.testing.expectEqual(@as(u32, 5), instrCost(.unpack_struct));
    try std.testing.expectEqual(@as(u32, 5), instrCost(.any_pack_move));
}
