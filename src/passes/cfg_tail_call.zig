//! Pass: tail-call optimization (frontend.md §7, ir.md §10.10). In: a
//! lowered `cfg.IrProgram`. Out: the same program, with every direct call
//! in tail position to the enclosing function rewritten into a
//! frame-reusing jump back to a loop header, so self-recursion becomes
//! iteration.
//!
//! A call is in tail position when its result flows — through nothing but
//! SSA phis — into the function's `ret` (§7.1); a void call is in tail
//! position when only `const void` noise (the lowerer's `emitVoid`)
//! separates it from a bare `ret`. Only *direct* calls to the enclosing
//! `IrFunc` are candidates (§7.3): a call through a function value has no
//! statically known target, a call to another function keeps its ordinary
//! `call`, and a `never` call ends in `trap`. The rewrite never reorders
//! a `drop` or observable effect: the call must be the last instruction
//! of its block — a scope-end `drop` would sit after it — and every
//! intermediate block in the result chain must contain only phis, so no
//! unique state is live across the boundary. Two further preconditions
//! keep the chain drop sound (§7.2): an intermediate chain block (any
//! block between the call block and the ret block) must have exactly one
//! predecessor, so it forwards only the call's result — an extra
//! predecessor merges another arm's value, which dropping the chain edge
//! would strand; and the ret block must keep at least one non-chain
//! predecessor, or replacing every chain edge with a loop-back would
//! orphan the function's only `ret`. Both are conservative: the call
//! stays ordinary when either fails.
//!
//! The rewrite (§7.2) replaces the `call`+`ret` pair with a `br` back to
//! the function's own entry block, re-binding the callee parameters from
//! the call's arguments: the entry block becomes a loop header holding
//! one phi per parameter (the entry values merged with the loop-back
//! arguments), and every use of a raw parameter is rewritten to its phi
//! result so the body reads the current iteration's values. Because the
//! text form's first block must have no predecessors (ir.md §13), a
//! no-pred trampoline forwards the entry to the header. Values are
//! renumbered in text order; the chain blocks the rewrite leaves
//! unreachable are removed by dead-block elimination (8.5), which runs
//! after this pass. Allocations use the program's backing allocator (the
//! arena); the pass frees nothing.

const std = @import("std");
const cfg = @import("../cfg.zig");

/// Rewrite every eligible self-recursive tail call into a loop.
pub fn tailCall(program: *cfg.IrProgram, allocator: std.mem.Allocator) !void {
    // The frontend's lowered CFG leaves `Call.callee.direct.func` null
    // (the standalone parser resolves it at parse time); a direct call is
    // eligible only against a known IrFunc (§7.3), so resolve first.
    // Idempotent: already-resolved calls are skipped.
    try program.resolveDirectCalls(allocator);
    for (program.funcs) |f| {
        try rewriteFunc(f, allocator);
    }
}

/// One rewrite: the block holding a tail call, the chain of blocks the
/// call's result flows through to the `ret`, and the call's arguments.
const TailCall = struct {
    block: *cfg.BasicBlock,
    instr: *cfg.Instr,
    chain: []*cfg.BasicBlock, // [block, ...]; the last block has a `.ret` terminator
    args: []*cfg.Value,
};

/// A use of a value, as seen by the tail-position walk.
const Use = union(enum) {
    /// The value is ret'ed in this block.
    ret: *cfg.BasicBlock,
    /// The value is a `[_, pred]` incoming of a phi in `block`.
    phi: struct { block: *cfg.BasicBlock, pred: *cfg.BasicBlock },
    /// Any other operand position.
    other,
};

// ---------------------------------------------------------------------------
// Tail-position detection (§7.1)
// ---------------------------------------------------------------------------

/// Collect the tail-position self-calls of `f`: direct `call`
/// instructions to `f` itself whose result reaches a `ret` (or, for a
/// void call, only `const void` noise away from one).
fn findTailCalls(f: *cfg.IrFunc, allocator: std.mem.Allocator) ![]TailCall {
    var tails = std.ArrayList(TailCall).empty;
    for (f.blocks) |b| {
        for (b.instrs) |instr| {
            if (instr.op != .call) continue;
            const c = instr.op.call;
            if (c.callee != .direct) continue;
            if (c.callee.direct.func != f) continue; // self-recursion only
            const chain = if (instr.results.len > 0)
                try resultChain(f, b, instr.results[0], allocator)
            else
                try voidChain(b, instr, allocator);
            if (chain) |ch| {
                try tails.append(allocator, .{
                    .block = b,
                    .instr = instr,
                    .chain = ch,
                    .args = c.args,
                });
            }
        }
    }
    return tails.toOwnedSlice(allocator);
}

/// The chain of blocks a *result* call's value flows through to a `ret`:
/// the call's own block, then phi-only joins, ending in the block that
/// rets the value. Null when the value does not reach a single `ret` —
/// its only use is either a ret (in the block itself or a phi-only block
/// the current block branches to) or a phi incoming whose predecessor is
/// the current block, continuing the walk.
fn resultChain(f: *cfg.IrFunc, block: *cfg.BasicBlock, result: *cfg.Value, allocator: std.mem.Allocator) !?[]*cfg.BasicBlock {
    var chain = std.ArrayList(*cfg.BasicBlock).empty;
    defer chain.deinit(allocator);
    var visited = std.AutoHashMap(*cfg.BasicBlock, void).init(allocator);
    defer visited.deinit();

    try chain.append(allocator, block);
    var cur_block = block;
    var cur_val = result;
    while (true) {
        if (visited.contains(cur_block)) return null; // phi cycle: no ret
        try visited.put(cur_block, {});
        var uses = try collectUses(f, cur_val, allocator);
        defer uses.deinit(allocator);
        if (uses.items.len != 1) return null;
        switch (uses.items[0]) {
            .other => return null,
            .ret => |t| {
                if (t == cur_block) return finishChain(&chain, allocator);
                // The block branches to a phi-only block that rets it.
                if (cur_block.terminator != .branch) return null;
                if (cur_block.terminator.branch != t) return null;
                if (!isPhiOnly(t)) return null;
                try chain.append(allocator, t);
                return finishChain(&chain, allocator);
            },
            .phi => |p| {
                if (p.pred != cur_block) return null;
                if (cur_block.terminator != .branch) return null;
                if (cur_block.terminator.branch != p.block) return null;
                if (!isPhiOnly(p.block)) return null;
                const next = phiResult(p.block, cur_block, cur_val) orelse return null;
                cur_block = p.block;
                cur_val = next;
                try chain.append(allocator, cur_block);
            },
        }
    }
}

/// Take the completed chain, or `null` when an *intermediate* chain block
/// has more than one predecessor. The chain's last block is the ret block
/// and may merge other arms' values; every block between the call block
/// and the ret block, however, must forward only the call's result — with
/// extra predecessors it merges values the rewrite's chain-edge drop
/// would strand, changing what the ret block receives (multi-arm guarded
/// recursion, §7.2).
fn finishChain(chain: *std.ArrayList(*cfg.BasicBlock), allocator: std.mem.Allocator) !?[]*cfg.BasicBlock {
    for (chain.items[1 .. chain.items.len - 1]) |b| {
        if (b.preds.len != 1) return null;
    }
    return try chain.toOwnedSlice(allocator);
}

/// The chain of blocks a *void* call's flow reaches a bare `ret` through:
/// the call's own block (where only `const void` may follow the call),
/// then noise-only joins. Null when a trap or non-void work intervenes.
fn voidChain(block: *cfg.BasicBlock, call_instr: *cfg.Instr, allocator: std.mem.Allocator) !?[]*cfg.BasicBlock {
    var after = false;
    for (block.instrs) |instr| {
        if (instr == call_instr) {
            after = true;
        } else if (after and !isVoidNoise(instr)) {
            return null;
        }
    }
    var chain = std.ArrayList(*cfg.BasicBlock).empty;
    defer chain.deinit(allocator);
    var visited = std.AutoHashMap(*cfg.BasicBlock, void).init(allocator);
    defer visited.deinit();

    try chain.append(allocator, block);
    var cur = block;
    while (true) {
        if (visited.contains(cur)) return null; // branch cycle: no ret
        try visited.put(cur, {});
        switch (cur.terminator) {
            .ret => |r| {
                // A void tail call must reach a bare `ret`.
                if (r != null) return null;
                return try chain.toOwnedSlice(allocator);
            },
            .branch => |next| {
                if (!isNoiseOnly(next)) return null;
                // An intermediate (branching) chain block must forward
                // only the call: with extra predecessors it merges other
                // arms' void values, which the chain-edge drop strands
                // (multi-arm guarded recursion, §7.2). The ret block may
                // keep other predecessors — its non-chain values are
                // preserved.
                if (next.terminator == .branch and next.preds.len != 1) return null;
                try chain.append(allocator, next);
                cur = next;
            },
            else => return null,
        }
    }
}

/// True when every instruction in `b` is a phi.
fn isPhiOnly(b: *const cfg.BasicBlock) bool {
    for (b.instrs) |instr| {
        if (instr.op != .phi) return false;
    }
    return true;
}

/// True when every instruction in `b` is a phi or a `const void` (void
/// joins emit the latter instead of a phi).
fn isNoiseOnly(b: *const cfg.BasicBlock) bool {
    for (b.instrs) |instr| {
        if (instr.op != .phi and !isVoidNoise(instr)) return false;
    }
    return true;
}

/// True for the `const void` instructions `emitVoid` leaves behind.
fn isVoidNoise(instr: *const cfg.Instr) bool {
    return instr.op == .const_ and instr.op.const_ == .void;
}

/// The result of the phi in `b` whose incoming `[v, pred]` matches the
/// given value and predecessor; null when there is no such phi.
fn phiResult(b: *const cfg.BasicBlock, pred: *const cfg.BasicBlock, v: *const cfg.Value) ?*cfg.Value {
    for (b.instrs) |instr| {
        if (instr.op != .phi) continue;
        for (instr.op.phi.incoming) |inc| {
            if (inc.pred == pred and inc.value == v) return instr.results[0];
        }
    }
    return null;
}

/// The uses of `v` in `f`, up to two (any more disqualify the candidate).
fn collectUses(f: *cfg.IrFunc, v: *cfg.Value, allocator: std.mem.Allocator) !std.ArrayList(Use) {
    var uses = std.ArrayList(Use).empty;
    outer: for (f.blocks) |b| {
        for (b.instrs) |instr| {
            if (instr.op == .phi) {
                for (instr.op.phi.incoming) |inc| {
                    if (inc.value == v) {
                        try uses.append(allocator, .{ .phi = .{ .block = b, .pred = inc.pred } });
                        if (uses.items.len > 1) break :outer;
                    }
                }
            } else if (instrUses(instr, v)) {
                try uses.append(allocator, .other);
                if (uses.items.len > 1) break :outer;
            }
        }
        switch (b.terminator) {
            .ret => |rv| {
                if (rv) |val| if (val == v) {
                    try uses.append(allocator, .{ .ret = b });
                    if (uses.items.len > 1) break :outer;
                };
            },
            .branch => {},
            .branch_cond => |bc| {
                if (bc.cond == v) {
                    try uses.append(allocator, .other);
                    if (uses.items.len > 1) break :outer;
                }
            },
            .@"switch" => |s| {
                if (s.disc == v) {
                    try uses.append(allocator, .other);
                    if (uses.items.len > 1) break :outer;
                }
            },
            .trap => {},
        }
    }
    return uses;
}

/// True when `v` is read as an operand of `instr` (phi handled by the
/// caller).
fn instrUses(instr: *const cfg.Instr, v: *const cfg.Value) bool {
    return switch (instr.op) {
        .neg, .not_, .num_cast, .any_pack_copy, .any_pack_move, .any_unpack_copy, .any_unpack_move, .cleanup_owner, .cleanup_disable, .drop_cleanup, .copy, .borrow, .move_, .tail, .unpack_struct, .unpack_tuple, .split_list, .read_tag, .read_payload, .drop_ => |x| x == v,
        .unpack_variant => |uv| uv.base == v,
        .type_is => |x| x.value == v,
        .add, .sub, .mul, .div, .rem, .concat, .eq, .ne, .lt, .le, .gt, .ge => |x| x.a == v or x.b == v,
        .load_member => |x| x.module == v,
        .store_member => |x| x.value == v,
        .construct => |x| for (x.args) |a| {
            if (a == v) break true;
        } else false,
        .read_field, .read_tuple => |x| x.base == v,
        .read_index => |x| x.base == v or x.index == v,
        .call => |x| if (x.callee == .value) x.callee.value == v else for (x.args) |a| {
            if (a == v) break true;
        } else false,
        .syscall => |x| for (x.args) |a| {
            if (a == v) break true;
        } else false,
        .const_, .module_ref, .fn_ref => false,
        .phi => false,
    };
}

// ---------------------------------------------------------------------------
// The rewrite (§7.2)
// ---------------------------------------------------------------------------

fn rewriteFunc(f: *cfg.IrFunc, allocator: std.mem.Allocator) !void {
    const tails = try findTailCalls(f, allocator);
    defer allocator.free(tails);
    if (tails.len == 0) return;

    // A rewrite replaces the call block's branch to its ret block with a
    // loop-back, dropping that chain edge from the ret block. When every
    // predecessor of a ret block is the call block of a tail call whose
    // chain ends there, the ret block would be left with no predecessors
    // (dead-block elimination would delete the function's only `ret`), so
    // the whole group is left un-rewritten — the calls stay ordinary.
    var keep = try filterOrphanedTails(tails, allocator);
    defer keep.deinit(allocator);
    if (keep.items.len == 0) return;
    const tails_ = keep.items;

    const header = f.entry;
    const header_name = try uniqueName(f, "header", allocator);
    header.name = header_name;
    // The old entry is now the header, so "entry" is free for the trampoline.
    const tramp_name = try uniqueName(f, "entry", allocator);

    // The text form's first block must have no predecessors (ir.md §13),
    // so a trampoline becomes the new entry and forwards to the header.
    var max_id: u32 = 0;
    for (f.blocks) |b| max_id = @max(max_id, b.id);
    const trampoline = try allocator.create(cfg.BasicBlock);
    trampoline.* = .{
        .id = max_id + 1,
        .span = header.span,
        .name = tramp_name,
        .instrs = &.{},
        .terminator = .{ .branch = header },
        .preds = &.{},
    };

    var blocks = std.ArrayList(*cfg.BasicBlock).empty;
    try blocks.append(allocator, trampoline);
    for (f.blocks) |b| try blocks.append(allocator, b);
    f.blocks = try blocks.toOwnedSlice(allocator);
    f.entry = trampoline;

    // Detach each tail call: drop the call instruction and its chain
    // edges, and branch the block to the header instead of its old ret.
    for (tails_) |t| {
        var instrs = std.ArrayList(*cfg.Instr).empty;
        for (t.block.instrs) |instr| {
            if (instr != t.instr) try instrs.append(allocator, instr);
        }
        t.block.instrs = try instrs.toOwnedSlice(allocator);
        for (0..t.chain.len - 1) |i| {
            try dropPred(t.chain[i + 1], t.chain[i], allocator);
        }
        t.block.terminator = .{ .branch = header };
    }

    // The header's predecessors, in the same order as the phi incomings:
    // the trampoline first, then one edge per tail call.
    var hpreds = std.ArrayList(*cfg.BasicBlock).empty;
    try hpreds.append(allocator, trampoline);
    for (tails_) |t| try hpreds.append(allocator, t.block);
    header.preds = try hpreds.toOwnedSlice(allocator);

    // One phi per parameter, merging the entry values with the loop-back
    // arguments. Every use of a raw parameter is later rewritten to its
    // phi result, so the trampoline incoming must keep the raw parameter
    // — the phis themselves are exempt from that rewrite.
    var max_v: u32 = 0;
    for (f.values) |v| max_v = @max(max_v, v.id);
    const params = f.values[0..f.params.len];

    var phi_results = std.ArrayList(*cfg.Value).empty;
    defer phi_results.deinit(allocator);
    for (params, 0..) |p, i| {
        const pv = try allocator.create(cfg.Value);
        pv.* = .{
            .id = max_v + 1 + @as(u32, @intCast(i)),
            .span = f.params[i].span,
            .type_ = p.type_,
            .ownership = p.ownership,
            .state = p.state,
            .origin = null,
            .def = null,
        };
        try phi_results.append(allocator, pv);
    }

    var renames = std.AutoHashMap(*cfg.Value, *cfg.Value).init(allocator);
    defer renames.deinit();
    for (params, 0..) |p, i| try renames.put(p, phi_results.items[i]);

    var phi_instrs = std.ArrayList(*cfg.Instr).empty;
    defer phi_instrs.deinit(allocator);
    for (params, 0..) |p, i| {
        const incoming = try allocator.alloc(cfg.PhiIn, tails_.len + 1);
        incoming[0] = .{ .value = p, .pred = trampoline };
        for (tails_, 0..) |t, j| {
            const arg = t.args[i];
            incoming[j + 1] = .{ .value = renames.get(arg) orelse arg, .pred = t.block };
        }
        const instr = try allocator.create(cfg.Instr);
        const results = try allocator.alloc(*cfg.Value, 1);
        results[0] = phi_results.items[i];
        instr.* = .{
            .span = f.params[i].span,
            .results = results,
            .op = .{ .phi = .{ .incoming = incoming } },
        };
        phi_results.items[i].def = instr;
        try phi_instrs.append(allocator, instr);
    }
    const header_instrs = try allocator.alloc(*cfg.Instr, header.instrs.len + phi_instrs.items.len);
    @memcpy(header_instrs[0..phi_instrs.items.len], phi_instrs.items);
    @memcpy(header_instrs[phi_instrs.items.len..], header.instrs);
    header.instrs = header_instrs;

    var skip = std.AutoHashMap(*cfg.Instr, void).init(allocator);
    defer skip.deinit();
    for (phi_instrs.items) |instr| try skip.put(instr, {});
    for (f.blocks) |b| rewriteBlock(b, &renames, &skip);

    try cfg.renumberValues(f, allocator);
}

/// Drop `pred` from `b`'s predecessor list and every phi incoming whose
/// predecessor is `pred`, keeping the one-incoming-per-pred contract
/// (ir.md §4.3).
fn dropPred(b: *cfg.BasicBlock, pred: *cfg.BasicBlock, allocator: std.mem.Allocator) !void {
    var preds = std.ArrayList(*cfg.BasicBlock).empty;
    for (b.preds) |p| {
        if (p != pred) try preds.append(allocator, p);
    }
    b.preds = try preds.toOwnedSlice(allocator);
    for (b.instrs) |instr| {
        if (instr.op != .phi) continue;
        const phi = &instr.op.phi;
        var incoming = std.ArrayList(cfg.PhiIn).empty;
        for (phi.incoming) |inc| {
            if (inc.pred != pred) try incoming.append(allocator, inc);
        }
        phi.incoming = try incoming.toOwnedSlice(allocator);
    }
}

/// Drop every tail call whose rewrite would orphan its ret block: when
/// every predecessor of the ret block is the call block of a tail call
/// whose chain ends there, replacing all of those branches with loop-backs
/// leaves the ret block with no predecessors (unreachable; dead-block
/// elimination would delete the function's only `ret`). The whole group is
/// skipped so the calls stay ordinary.
fn filterOrphanedTails(tails: []const TailCall, allocator: std.mem.Allocator) !std.ArrayList(TailCall) {
    var keep = std.ArrayList(TailCall).empty;
    var group = std.AutoHashMap(*cfg.BasicBlock, std.ArrayList(usize)).init(allocator);
    defer group.deinit();
    for (tails, 0..) |t, i| {
        const bn = t.chain[t.chain.len - 1];
        const gop = try group.getOrPut(bn);
        if (!gop.found_existing) gop.value_ptr.* = std.ArrayList(usize).empty;
        try gop.value_ptr.append(allocator, i);
    }
    var iter = group.iterator();
    while (iter.next()) |e| {
        var orphaned = true;
        for (e.key_ptr.*.preds) |p| {
            var dropped_edge = false;
            for (e.value_ptr.items) |i| {
                if (tails[i].block == p) {
                    dropped_edge = true;
                    break;
                }
            }
            if (!dropped_edge) {
                orphaned = false;
                break;
            }
        }
        if (orphaned) continue; // ret block would lose every predecessor
        for (e.value_ptr.items) |i| try keep.append(allocator, tails[i]);
    }
    return keep;
}

/// A block name not already used in `f`, for the trampoline and header.
fn uniqueName(f: *cfg.IrFunc, base: []const u8, allocator: std.mem.Allocator) ![]const u8 {
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
        if (!taken) return candidate;
        n += 1;
    }
}

/// Rewrite every operand of `b`'s instructions and terminator that is a
/// renamed parameter to its phi result, skipping the header phis.
fn rewriteBlock(b: *cfg.BasicBlock, renames: *const std.AutoHashMap(*cfg.Value, *cfg.Value), skip: *const std.AutoHashMap(*cfg.Instr, void)) void {
    for (b.instrs) |instr| {
        if (skip.contains(instr)) continue;
        rewriteInstr(instr, renames);
    }
    switch (b.terminator) {
        .ret => |v| {
            if (v) |val| b.terminator.ret = renames.get(val) orelse val;
        },
        .branch => {},
        .branch_cond => |*bc| bc.cond = renames.get(bc.cond) orelse bc.cond,
        .@"switch" => |*s| s.disc = renames.get(s.disc) orelse s.disc,
        .trap => {},
    }
}

/// Rewrite the value operands of `instr` in place.
fn rewriteInstr(instr: *cfg.Instr, renames: *const std.AutoHashMap(*cfg.Value, *cfg.Value)) void {
    switch (instr.op) {
        .neg, .not_, .num_cast, .any_pack_copy, .any_pack_move, .any_unpack_copy, .any_unpack_move, .cleanup_owner, .cleanup_disable, .drop_cleanup, .copy, .borrow, .move_, .tail, .unpack_struct, .unpack_tuple, .split_list, .read_tag, .read_payload, .drop_ => |*v| {
            v.* = renames.get(v.*) orelse v.*;
        },
        .unpack_variant => |*uv| uv.base = renames.get(uv.base) orelse uv.base,
        .type_is => |*x| x.value = renames.get(x.value) orelse x.value,
        .add, .sub, .mul, .div, .rem, .concat, .eq, .ne, .lt, .le, .gt, .ge => |*x| {
            x.a = renames.get(x.a) orelse x.a;
            x.b = renames.get(x.b) orelse x.b;
        },
        .load_member => |*x| x.module = renames.get(x.module) orelse x.module,
        .store_member => |*x| x.value = renames.get(x.value) orelse x.value,
        .construct => |*x| {
            for (x.args) |*a| a.* = renames.get(a.*) orelse a.*;
        },
        .read_field, .read_tuple => |*x| x.base = renames.get(x.base) orelse x.base,
        .read_index => |*x| {
            x.base = renames.get(x.base) orelse x.base;
            x.index = renames.get(x.index) orelse x.index;
        },
        .call => |*x| {
            if (x.callee == .value) x.callee.value = renames.get(x.callee.value) orelse x.callee.value;
            for (x.args) |*a| a.* = renames.get(a.*) orelse a.*;
        },
        .syscall => |*x| {
            for (x.args) |*a| a.* = renames.get(a.*) orelse a.*;
        },
        .phi => |*x| {
            for (x.incoming) |*inc| inc.value = renames.get(inc.value) orelse inc.value;
        },
        .const_, .module_ref, .fn_ref => {},
    }
}
