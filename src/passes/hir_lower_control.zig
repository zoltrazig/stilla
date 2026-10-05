//! Pass: HIR control-flow lowering (docs/hir.md §9, §5.5).
//! In: Ctx + FuncState + an `if`/`and`/`or`/`match` node. Out: the CFG
//! diamonds — `br`/`switch` terminators and join phis — replicating
//! `cfg_lower_control`'s shapes block for block. `and`/`or` keep their
//! own HIR rows (§5.5 amendment) so the short-circuit diamonds can be
//! reproduced exactly.

const std = @import("std");
const ast = @import("stilla").ast;
const cfg = @import("stilla").cfg;
const hir = @import("stilla").hir;
const moduleinfo = @import("stilla").moduleinfo;
const lower = @import("stilla").lower;
const cfg_lower_emit = @import("cfg_lower_emit.zig");
const cfg_lower_expr = @import("cfg_lower_expr.zig");
const cfg_lower_control = @import("cfg_lower_control.zig");
const cfg_lower_intrinsic = @import("cfg_lower_intrinsic.zig");
const hir_lower = @import("hir_lower.zig");
const hir_lower_expr = @import("hir_lower_expr.zig");
const hir_lower_pattern = @import("hir_lower_pattern.zig");

const Ctx = hir_lower.Ctx;
const Lowerer = lower.Lowerer;
const FuncState = lower.FuncState;
const LowerError = lower.LowerError;
const JoinIn = cfg_lower_control.JoinIn;
const no_span = hir_lower.no_span;

fn is(t: []const u8, name: []const u8) bool {
    return std.mem.eql(u8, t, name);
}

/// A branch-shaped node: `if` (regions then/else) and the `and`/`or`
/// rows (regions rhs / const arm). Dispatch by op name.
pub fn branch(c: *Ctx, fs: *FuncState, id: hir.ExprId) LowerError!?*cfg.Value {
    const name = c.opName(id);
    if (is(name, "if")) return ifNode(c, fs, id);
    if (is(name, "and")) return andOr(c, fs, id, false);
    if (is(name, "or")) return andOr(c, fs, id, true);
    return c.self.fail(no_span, "'{s}' is not a branch op", .{name});
}

/// `if`: the cond (wrapped), then the two regions — a block-shaped
/// then root pushes its scope (the direct `lowerBlock`), the else root
/// likewise when block-shaped (Core §13.2).
fn ifNode(c: *Ctx, fs: *FuncState, id: hir.ExprId) LowerError!?*cfg.Value {
    const self = c.self;
    const regions = c.regionsOf(id);
    const then_root = c.built.program.region(regions[0]).root;
    const else_root = c.built.program.region(regions[1]).root;

    const cond = (try hir_lower_expr.expr(c, fs, c.operands(id)[0])) orelse return null;
    const track = try cfg_lower_emit.beginCond(self, fs, no_span);
    const then_block = try cfg_lower_emit.newBlock(self, fs, "then");
    const else_block = try cfg_lower_emit.newBlock(self, fs, "else");
    try cfg_lower_emit.setTerminator(self, fs, .{ .br = .{ .cond = cond, .then_ = then_block, .else_ = else_block } });
    const join = try cfg_lower_emit.newBlock(self, fs, "join");

    // Then branch.
    fs.cur = then_block;
    const then_val = try regionValue(c, fs, then_root);
    // The phi input's predecessor is the block that actually branches
    // to the join (the inner join for a nested then).
    const then_pred = fs.cur;
    const then_liv = try cfg_lower_emit.condLiveness(self, fs, track);
    if (then_pred != null) try cfg_lower_emit.setTerminator(self, fs, .{ .j = join });
    cfg_lower_emit.restoreCond(self, fs, track);

    // Else branch.
    fs.cur = else_block;
    const else_val = try regionValue(c, fs, else_root);
    const else_pred = fs.cur;
    const else_liv = try cfg_lower_emit.condLiveness(self, fs, track);
    if (else_pred != null) try cfg_lower_emit.setTerminator(self, fs, .{ .j = join });
    cfg_lower_emit.restoreCond(self, fs, track);

    const completing = @as(u2, @intFromBool(then_val != null)) + @as(u2, @intFromBool(else_val != null));
    if (completing == 0) {
        // Every branch trapped: the join stays as a trap-terminated
        // dead block (the direct lowering's rule).
        try cfg_lower_control.trapUnreachableJoin(self, fs, join);
        return null;
    }
    fs.cur = join;
    try cfg_lower_emit.joinMaybeFlags(self, fs, track, no_span, &.{
        .{ .pred = then_pred, .released = then_liv, .out_val = then_val },
        .{ .pred = else_pred, .released = else_liv, .out_val = else_val },
    });
    return try cfg_lower_control.makeJoinPhi(self, fs, join, no_span, &.{
        .{ .v = then_val, .b = then_pred orelse then_block },
        .{ .v = else_val, .b = else_pred orelse else_block },
    });
}

/// One branch region: a block-shaped root (an AST block with
/// statements/bindings) pushes its scope; the value is lowered with its
/// full-expression boundary either way.
fn regionValue(c: *Ctx, fs: *FuncState, root: hir.ExprId) LowerError!?*cfg.Value {
    const push = hir_lower.rootIsBlockShaped(c, root);
    if (push) try fs.scopes.append(c.self.arena, .{});
    const v = try hir_lower_expr.expr(c, fs, root);
    if (push) try cfg_lower_emit.exitScope(c.self, fs, v);
    return v;
}

/// `and`/`or`: the reference short-circuit diamond (air.md §14.2) —
/// `br` to rhs vs. the constant arm, a join phi over the rhs value and
/// the constant. Region order mirrors the builder's `controlNode`: for
/// `and` [rhs, const-false] (rhs is the then-arm), for `or`
/// [const-true, rhs] (the constant is the then-arm).
fn andOr(c: *Ctx, fs: *FuncState, id: hir.ExprId, is_or: bool) LowerError!?*cfg.Value {
    const self = c.self;
    const regions = c.regionsOf(id);
    const rhs_root = c.built.program.region(regions[if (is_or) 1 else 0]).root;
    const const_id = c.built.program.region(regions[if (is_or) 0 else 1]).root;

    const lhs = (try hir_lower_expr.expr(c, fs, c.operands(id)[0])) orelse return null;
    const track = try cfg_lower_emit.beginCond(self, fs, no_span);
    const rhs_block = try cfg_lower_emit.newBlock(self, fs, "rhs");
    const const_block = try cfg_lower_emit.newBlock(self, fs, if (is_or) "true_" else "false_");
    const then_ = if (is_or) const_block else rhs_block;
    const else_ = if (is_or) rhs_block else const_block;
    try cfg_lower_emit.setTerminator(self, fs, .{ .br = .{ .cond = lhs, .then_ = then_, .else_ = else_ } });

    // Right operand: evaluated only when needed. A never rhs traps
    // inside rhs_block and contributes no phi input (the join still
    // receives the constant arm).
    fs.cur = rhs_block;
    const rhs = try hir_lower_expr.expr(c, fs, rhs_root);
    const join = try cfg_lower_emit.newBlock(self, fs, "join");
    // The phi input's predecessor is the block that actually branches
    // to the join (the inner join for a nested rhs).
    const rhs_join_pred = fs.cur;
    const rhs_liv = try cfg_lower_emit.condLiveness(self, fs, track);
    if (rhs_join_pred != null) try cfg_lower_emit.setTerminator(self, fs, .{ .j = join });
    cfg_lower_emit.restoreCond(self, fs, track);

    // Constant arm (consumes nothing).
    fs.cur = const_block;
    const cval = (try hir_lower_expr.expr(c, fs, const_id)) orelse return null;
    const cval_liv = try cfg_lower_emit.condLiveness(self, fs, track);
    try cfg_lower_emit.setTerminator(self, fs, .{ .j = join });
    cfg_lower_emit.restoreCond(self, fs, track);

    fs.cur = join;
    try cfg_lower_emit.joinMaybeFlags(self, fs, track, no_span, &.{
        .{ .pred = rhs_join_pred, .released = rhs_liv, .out_val = rhs },
        .{ .pred = const_block, .released = cval_liv, .out_val = cval },
    });
    return try cfg_lower_control.makeJoinPhi(self, fs, join, no_span, &.{
        .{ .v = rhs, .b = rhs_join_pred orelse rhs_block },
        .{ .v = cval, .b = const_block },
    });
}

/// `match`: a union scrutinee dispatches through `read_tag` + `switch`;
/// every other type runs the literal/type-test/list test chain — the
/// two `cfg_lower_control` forms, driven by HIR patterns (whose variant
/// tags and field indexes the builder already resolved).
pub fn match(c: *Ctx, fs: *FuncState, id: hir.ExprId) LowerError!?*cfg.Value {
    const scrut_id = c.operands(id)[0];
    const moving = is(c.opName(scrut_id), "move");
    const scrut = (try hir_lower_expr.expr(c, fs, scrut_id)) orelse return null;
    if (scrut.type_ == .named) {
        if (c.built.types[scrut.type_.named.id] == .union_) {
            return unionMatch(c, fs, id, scrut, moving);
        }
    }
    return patternMatch(c, fs, id, scrut, moving);
}

/// A union match: `read_tag` + `switch` over variant discriminants,
/// first-match-wins coverage, per-arm payload binds and join phi
/// (air.md §14.3).
fn unionMatch(c: *Ctx, fs: *FuncState, id: hir.ExprId, scrut: *cfg.Value, moving: bool) LowerError!?*cfg.Value {
    const self = c.self;
    const regions = c.regionsOf(id);
    const n_arms = regions.len;
    const td = c.built.types[scrut.type_.named.id];
    const n_variants: usize = td.union_.variants.len;

    const tag = (try cfg_lower_emit.emit(self, fs, no_span, .{ .read_tag = scrut }, .{ .primitive = .uint32 })).?;
    // `match (move s)` transfers the whole owner (Core §13.4); marked
    // before `beginCond` so the scrutinee is not a maybe-unique
    // candidate.
    if (moving) cfg_lower_emit.markConsumed(self, fs, scrut);
    const track = try cfg_lower_emit.beginCond(self, fs, no_span);

    // First-match-wins coverage (Core §13.3).
    const cover_arm = try self.arena.alloc(?usize, n_variants);
    @memset(cover_arm, null);
    var catchall: ?usize = null;
    const live = try self.arena.alloc(bool, n_arms);
    @memset(live, false);
    for (regions, 0..) |rid, i| {
        if (catchall != null) continue; // fully covered: dead arm
        const pat_id = c.built.program.region(rid).pattern orelse
            return self.fail(no_span, "union-match arm has no pattern", .{});
        if (hir_lower_pattern.isCatchAll(c, pat_id)) {
            live[i] = true;
            catchall = i;
            continue;
        }
        const vtag = try hir_lower_pattern.variantTag(c, pat_id);
        if (vtag >= n_variants) return self.fail(no_span, "variant tag out of range", .{});
        if (cover_arm[vtag] != null) continue; // duplicate variant: dead
        cover_arm[vtag] = i;
        live[i] = true;
    }

    // One arm block per live arm; every tag dispatches to its covering
    // arm (uncovered tags trap — phase 2 checked exhaustiveness).
    var arm_blocks = std.ArrayList(*cfg.BasicBlock).empty;
    const block_of = try self.arena.alloc(?*cfg.BasicBlock, n_arms);
    @memset(block_of, null);
    for (regions, 0..) |_, i| {
        if (!live[i]) continue;
        const ab = try cfg_lower_emit.newBlock(self, fs, try cfg_lower_emit.fmtBlockName(self, "arm", i));
        try arm_blocks.append(self.arena, ab);
        block_of[i] = ab;
    }
    var arms = std.ArrayList(cfg.SwitchArm).empty;
    for (0..n_variants) |ti| {
        const b = if (cover_arm[ti]) |i| block_of[i].? else if (catchall) |i| block_of[i].? else continue;
        try arms.append(self.arena, .{ .tag = @intCast(ti), .block = b });
    }
    try cfg_lower_emit.setTerminator(self, fs, .{ .@"switch" = .{ .disc = tag, .arms = arms.items } });
    const join = try cfg_lower_emit.newBlock(self, fs, "join");
    var incoming = std.ArrayList(JoinIn).empty;
    var branches = std.ArrayList(cfg_lower_emit.CondBranch).empty;
    for (regions, 0..) |rid, i| {
        if (!live[i]) continue;
        const ab = block_of[i].?;
        fs.cur = ab;
        try fs.scopes.append(self.arena, .{});
        try hir_lower_pattern.bindUnionArm(c, fs, rid, scrut, moving);
        const v = try armBody(c, fs, rid);
        try cfg_lower_emit.exitScope(self, fs, v);
        const pred = fs.cur orelse ab;
        try incoming.append(self.arena, .{ .v = v, .b = pred });
        const arm_liv = try cfg_lower_emit.condLiveness(self, fs, track);
        try branches.append(self.arena, .{ .pred = fs.cur, .released = arm_liv, .out_val = v });
        if (fs.cur != null) try cfg_lower_emit.setTerminator(self, fs, .{ .j = join });
        cfg_lower_emit.restoreCond(self, fs, track);
    }
    return finishMatch(self, fs, track, join, &incoming, &branches);
}

/// A non-union match: literal/type-test/list test chains, fallthrough
/// rule, per-arm binds and join phi (air.md §14.3, Core §14).
fn patternMatch(c: *Ctx, fs: *FuncState, id: hir.ExprId, scrut: *cfg.Value, moving: bool) LowerError!?*cfg.Value {
    const self = c.self;
    const regions = c.regionsOf(id);
    const n = regions.len;
    const track = try cfg_lower_emit.beginCond(self, fs, no_span);
    var arm_blocks = std.ArrayList(*cfg.BasicBlock).empty;
    for (regions, 0..) |_, i| {
        try arm_blocks.append(self.arena, try cfg_lower_emit.newBlock(self, fs, try cfg_lower_emit.fmtBlockName(self, "arm", i)));
    }
    // Fallthrough: the first arm that is not refutable — a literal, a
    // type-test, or a constraining list pattern tests; only `[..rest]`
    // and the irrefutable shapes fall through. Else the last arm.
    var fallthrough: usize = n - 1;
    for (regions, 0..) |rid, i| {
        const pat_id = c.built.program.region(rid).pattern orelse
            return self.fail(no_span, "match arm has no pattern", .{});
        if (hir_lower_pattern.refutable(c, pat_id)) continue;
        fallthrough = i;
        break;
    }
    // Test chain in the scrutinee's block: every condition of an arm
    // must hold; any failure falls through to the next arm's test.
    var cur_test = fs.cur orelse return null;
    var i: usize = 0;
    while (i < n and i != fallthrough) : (i += 1) {
        const next_test: *cfg.BasicBlock = if (i + 1 == fallthrough) arm_blocks.items[fallthrough] else try cfg_lower_emit.newBlock(self, fs, "test");
        var cond_block = cur_test;
        var k: usize = 0;
        while (true) : (k += 1) {
            fs.cur = cond_block;
            const cond = (try hir_lower_pattern.armTest(c, fs, scrut, regions[i], k)) orelse break;
            const has_next = try hir_lower_pattern.hasArmTest(c, regions[i], k + 1);
            const then_b = if (has_next) blk: {
                const nb = try cfg_lower_emit.newBlock(self, fs, "test");
                cond_block = nb;
                break :blk nb;
            } else arm_blocks.items[i];
            try cfg_lower_emit.setTerminator(self, fs, .{ .br = .{ .cond = cond, .then_ = then_b, .else_ = next_test } });
        }
        cur_test = next_test;
    }
    if (i == 0) {
        // No tests: straight to the fallthrough arm.
        fs.cur = cur_test;
        try cfg_lower_emit.setTerminator(self, fs, .{ .j = arm_blocks.items[fallthrough] });
    }
    const join = try cfg_lower_emit.newBlock(self, fs, "join");
    var incoming = std.ArrayList(JoinIn).empty;
    var branches = std.ArrayList(cfg_lower_emit.CondBranch).empty;
    for (regions, arm_blocks.items) |rid, ab| {
        fs.cur = ab;
        try fs.scopes.append(self.arena, .{});
        try hir_lower_pattern.bindPattern(c, fs, c.built.program.region(rid).pattern.?, scrut, moving);
        const v = try armBody(c, fs, rid);
        try cfg_lower_emit.exitScope(self, fs, v);
        const pred = fs.cur orelse ab;
        try incoming.append(self.arena, .{ .v = v, .b = pred });
        const arm_liv = try cfg_lower_emit.condLiveness(self, fs, track);
        try branches.append(self.arena, .{ .pred = fs.cur, .released = arm_liv, .out_val = v });
        if (fs.cur != null) try cfg_lower_emit.setTerminator(self, fs, .{ .j = join });
        cfg_lower_emit.restoreCond(self, fs, track);
    }
    return finishMatch(self, fs, track, join, &incoming, &branches);
}

/// An arm body: the region root with its full-expression boundary
/// (arm bodies are expressions — hir.md §5.2).
fn armBody(c: *Ctx, fs: *FuncState, rid: hir.RegionId) LowerError!?*cfg.Value {
    return hir_lower_expr.expr(c, fs, c.built.program.region(rid).root);
}

/// Shared match tail: the trap-unreachable rule, the maybe-unique
/// merge, and the join phi.
fn finishMatch(self: *Lowerer, fs: *FuncState, track: cfg_lower_emit.CondTrack, join: *cfg.BasicBlock, incoming: *std.ArrayList(JoinIn), branches: *std.ArrayList(cfg_lower_emit.CondBranch)) LowerError!?*cfg.Value {
    var completing: usize = 0;
    for (incoming.items) |inc| {
        if (inc.v != null) completing += 1;
    }
    if (completing == 0) {
        try cfg_lower_control.trapUnreachableJoin(self, fs, join);
        return null;
    }
    fs.cur = join;
    try cfg_lower_emit.joinMaybeFlags(self, fs, track, no_span, branches.items);
    return try cfg_lower_control.makeJoinPhi(self, fs, join, no_span, incoming.items);
}
