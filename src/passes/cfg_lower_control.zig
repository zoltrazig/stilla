//! Pass: control-flow lowering — `if-expression`, `match-expression`,
//! and short-circuit `and`/`or` (Core §10, §11, §13; air.md §14.2–§14.3).
//! In: Lowerer + FuncState + AST control-flow nodes, module graph. Out:
//! CFG blocks, `br`/`switch`/`branch` terminators, and join phis.

const std = @import("std");
const ast = @import("stilla").ast;
const cfg = @import("stilla").cfg;
const moduleinfo = @import("stilla").moduleinfo;
const type_resolve = @import("type_resolve.zig");
const lower = @import("stilla").lower;
const cfg_lower_expr = @import("cfg_lower_expr.zig");
const cfg_lower_call = @import("cfg_lower_call.zig");
const cfg_lower_func = @import("cfg_lower_func.zig");
const cfg_lower_pattern = @import("cfg_lower_pattern.zig");
const cfg_lower_emit = @import("cfg_lower_emit.zig");
const cfg_lower_intrinsic = @import("cfg_lower_intrinsic.zig");

const Lowerer = lower.Lowerer;
const FuncState = lower.FuncState;
const LowerError = lower.LowerError;
const isMoveExpr = cfg_lower_expr.isMoveExpr;

/// An incoming (value, predecessor) pair for a join phi, in edge order.
pub const JoinIn = struct {
    v: ?*cfg.Value,
    /// The block that actually branches to the join (the one fs.cur
    /// points at when the branch is set); for a nested rhs/arm/body
    /// that is the inner join block, not the branch's entry block.
    b: *cfg.BasicBlock,
};

/// `a and b`: the right operand is evaluated only when `a` is true —
/// a `br` diamond with a join phi (air.md §14.2, Runtime §5).
pub fn lowerAnd(self: *Lowerer, fs: *FuncState, b: *const ast.Binary) LowerError!?*cfg.Value {
    const lhs = (try cfg_lower_expr.lowerExpr(self, fs, b.lhs)) orelse return null;
    const track = try cfg_lower_emit.beginCond(self, fs, b.span);
    const rhs_block = try cfg_lower_emit.newBlock(self, fs, "rhs");
    const false_block = try cfg_lower_emit.newBlock(self, fs, "false_");
    try cfg_lower_emit.setTerminator(self, fs, .{ .br = .{ .cond = lhs, .then_ = rhs_block, .else_ = false_block } });
    // Right operand: evaluated only when the left is true.
    fs.cur = rhs_block;
    // A never right operand (`a and die()`) traps inside rhs_block: the
    // rhs side then contributes no phi input and no edge to the join
    // (the block is already terminated by the trap), and the join
    // still receives the const-false arm.
    const rhs = try cfg_lower_expr.lowerExpr(self, fs, b.rhs);
    const join = try cfg_lower_emit.newBlock(self, fs, "join");
    // The block that actually branches to the join is the one fs.cur
    // points at now — for a nested rhs (`a and (b and c)`) that is the
    // inner join block, not rhs_block — and it is the phi input's real
    // in-edge predecessor (air.md §4.3).
    const rhs_join_pred = fs.cur;
    const rhs_liv = try cfg_lower_emit.condLiveness(self, fs, track);
    if (rhs_join_pred != null) try cfg_lower_emit.setTerminator(self, fs, .{ .j = join });
    cfg_lower_emit.restoreCond(self, fs, track);
    // False arm: const false (consumes nothing).
    fs.cur = false_block;
    const fval = (try cfg_lower_expr.emitConst(self, fs, b.span, .{ .bool = false }, .{ .primitive = .bool })).?;
    const false_liv = try cfg_lower_emit.condLiveness(self, fs, track);
    try cfg_lower_emit.setTerminator(self, fs, .{ .j = join });
    cfg_lower_emit.restoreCond(self, fs, track);
    fs.cur = join;
    try cfg_lower_emit.joinMaybeFlags(self, fs, track, b.span, &.{
        .{ .pred = rhs_join_pred, .released = rhs_liv, .out_val = rhs },
        .{ .pred = false_block, .released = false_liv, .out_val = fval },
    });
    return try makeJoinPhi(self, fs, join, b.span, &.{
        .{ .v = rhs, .b = rhs_join_pred orelse rhs_block },
        .{ .v = fval, .b = false_block },
    });
}

/// `a or b`: the right operand is evaluated only when `a` is false.
pub fn lowerOr(self: *Lowerer, fs: *FuncState, b: *const ast.Binary) LowerError!?*cfg.Value {
    const lhs = (try cfg_lower_expr.lowerExpr(self, fs, b.lhs)) orelse return null;
    const track = try cfg_lower_emit.beginCond(self, fs, b.span);
    const rhs_block = try cfg_lower_emit.newBlock(self, fs, "rhs");
    const true_block = try cfg_lower_emit.newBlock(self, fs, "true_");
    try cfg_lower_emit.setTerminator(self, fs, .{ .br = .{ .cond = lhs, .then_ = true_block, .else_ = rhs_block } });
    fs.cur = rhs_block;
    // A never right operand (`a or die()`) traps inside rhs_block: the
    // rhs side then contributes no phi input and no edge to the join
    // (the block is already terminated by the trap), and the join
    // still receives the const-true arm.
    const rhs = try cfg_lower_expr.lowerExpr(self, fs, b.rhs);
    const join = try cfg_lower_emit.newBlock(self, fs, "join");
    // See lowerAnd: the phi input's predecessor is the block that
    // actually branches to the join (the inner join for a nested rhs).
    const rhs_join_pred = fs.cur;
    const rhs_liv = try cfg_lower_emit.condLiveness(self, fs, track);
    if (rhs_join_pred != null) try cfg_lower_emit.setTerminator(self, fs, .{ .j = join });
    cfg_lower_emit.restoreCond(self, fs, track);
    // True arm: const true (consumes nothing).
    fs.cur = true_block;
    const tval = (try cfg_lower_expr.emitConst(self, fs, b.span, .{ .bool = true }, .{ .primitive = .bool })).?;
    const true_liv = try cfg_lower_emit.condLiveness(self, fs, track);
    try cfg_lower_emit.setTerminator(self, fs, .{ .j = join });
    cfg_lower_emit.restoreCond(self, fs, track);
    fs.cur = join;
    try cfg_lower_emit.joinMaybeFlags(self, fs, track, b.span, &.{
        .{ .pred = rhs_join_pred, .released = rhs_liv, .out_val = rhs },
        .{ .pred = true_block, .released = true_liv, .out_val = tval },
    });
    return try makeJoinPhi(self, fs, join, b.span, &.{
        .{ .v = rhs, .b = rhs_join_pred orelse rhs_block },
        .{ .v = tval, .b = true_block },
    });
}

/// Discard the most recently created block (used when a join turns
/// out to be unreachable because every branch trapped).
/// Signal `never` for an unreachable join (every branch/arm trapped).
/// The join and the trapped branch blocks created after it are left in
/// place as trap-terminated dead blocks: pruning would require removing
/// blocks by id (ids are creation indices, so mid-list removal would
/// invalidate them) and re-terminating the surviving branch-entry
/// blocks, and dead trap blocks are already a normal part of the AIR
/// (never arms). `setTerminator` leaves `fs.cur == null`, which is the
/// caller's "trapped" signal.
pub fn trapUnreachableJoin(self: *Lowerer, fs: *FuncState, join: *cfg.BasicBlock) LowerError!void {
    fs.cur = join;
    try cfg_lower_emit.setTerminator(self, fs, .{ .trap = {} });
}

/// Create the join phi from the (value, predecessor) pairs. Values
/// are in edge order; a null value (a `trap`-terminated predecessor)
/// contributes no input (air.md §4.3). A void join produces no phi.
///
/// Ownership (air.md §6.3-6.4): an unique value listed as a phi input
/// is *not* destroyed at the end of its producing block — the phi
/// result becomes the single owner. The inputs are therefore marked
/// consumed here (their cleanup tokens disarmed), so the full-expression
/// `dropCreatedRange` and the branch-end scope drops skip them, and only
/// the phi result (the join-scope owner) receives a scope-end drop
/// unless ownership transfers (e.g. `ret` of the phi result).
///
/// Join typing (Core §13.2, air.md §4.4): the phi's type is the *join
/// type* of the incoming values — identical types join to themselves,
/// a mix coercible to `any` joins as `any` — and the `T → any` coercion
/// is materialized on each predecessor edge (`any_pack_copy` for a
/// Copy source, `any_pack_move` for an unique source) so the phi
/// is homogeneous and ownership stays explicit.
pub fn makeJoinPhi(
    self: *Lowerer,
    fs: *FuncState,
    join: *cfg.BasicBlock,
    span: ast.Span,
    incoming: []const JoinIn,
) LowerError!?*cfg.Value {
    std.debug.assert(fs.cur == join);
    // Order the inputs by predecessor block id. The join's in-edges are
    // materialized in block order during finalization (air.md §3, §4.3),
    // and the inputs' real predecessors are the blocks that *actually*
    // branch to the join — for a nested rhs/arm/body these are inner
    // join blocks created after the outer branch blocks (e.g. `a and (b
    // and c)` branches to the outer join from the inner `b and c` join),
    // so the natural call-site order does not match the in-edge order.
    // A null value (a trapped predecessor) is skipped below and never
    // appears in either list.
    var sorted = std.ArrayList(JoinIn).empty;
    try sorted.appendSlice(self.arena, incoming);
    std.mem.sort(JoinIn, sorted.items, {}, struct {
        fn lt(_: void, a: JoinIn, b: JoinIn) bool {
            return a.b.id < b.b.id;
        }
    }.lt);
    // The join type: unify the non-null incoming types exactly as phase 2
    // does (never contributes nothing, equal types join to themselves,
    // anything else joins as `any`).
    var join_type: ?cfg.Type = null;
    for (sorted.items) |inc| {
        const v = inc.v orelse continue;
        join_type = if (join_type) |jt| unifyType(jt, v.type_) else v.type_;
    }
    const jt = join_type orelse cfg.Type{ .primitive = .void };
    if (cfg_lower_emit.isVoid(jt)) return cfg_lower_expr.emitVoid(self, fs, span);
    // Materialize the `T → any` coercion on each predecessor edge whose
    // incoming type differs from the join type (air.md §4.4). The packed
    // value replaces the incoming in the phi; an unique source is moved
    // in (consumed, token disarmed) on its own edge.
    var packed_v = try self.arena.alloc(?*cfg.Value, sorted.items.len);
    for (sorted.items, 0..) |inc, i| {
        const v = inc.v orelse {
            packed_v[i] = null;
            continue;
        };
        if (cfg.Type.eql(v.type_, jt)) {
            packed_v[i] = v;
            continue;
        }
        const edge = inc.b;
        // A void branch value is a def-less phantom (emitVoid) — a real
        // `const void` is materialized on the edge so it can be packed.
        const src = if (cfg_lower_emit.isVoid(v.type_))
            (try cfg_lower_emit.emitInto(self, fs, edge, span, .{ .const_ = .void }, .{ .primitive = .void })).?
        else
            v;
        if (src.ownership == .unique) {
            const p = (try cfg_lower_emit.emitInto(self, fs, edge, span, .{ .any_pack_move = src }, jt)).?;
            cfg_lower_emit.markConsumed(self, fs, src);
            try cfg_lower_emit.cleanupDisableInto(self, fs, edge, span, src);
            packed_v[i] = p;
        } else {
            packed_v[i] = (try cfg_lower_emit.emitInto(self, fs, edge, span, .{ .any_pack_copy = src }, jt)).?;
        }
    }
    const phi = (try cfg_lower_emit.newPhi(self, fs, span, jt)).?;
    const builder = fs.phi_lists.get(phi.def.?) orelse unreachable;
    for (sorted.items, 0..) |inc, i| {
        const v = packed_v[i] orelse continue;
        cfg_lower_emit.markConsumed(self, fs, v);
        // A phi input with a cleanup token transfers ownership at the
        // join on every completing edge: disarm the token here — on a
        // path where the value was already consumed the token is already
        // disarmed, so this is idempotent.
        try cfg_lower_emit.cleanupDisable(self, fs, span, v);
        try builder.append(self.arena, .{ .value = v, .pred = inc.b });
    }
    return phi;
}

/// The join type of two branch values (Core §13.2, mirroring phase 2's
/// `unify`): `never` contributes nothing; equal types join to themselves;
/// a mixed pair joins as the top type `any`.
fn unifyType(a: cfg.Type, b: cfg.Type) cfg.Type {
    if (a == .primitive and a.primitive == .never) return b;
    if (b == .primitive and b.primitive == .never) return a;
    if (cfg.Type.eql(a, b)) return a;
    return cfg.Type{ .primitive = .any };
}

pub fn lowerIf(self: *Lowerer, fs: *FuncState, e: *const ast.IfExpr) LowerError!?*cfg.Value {
    const cond = (try cfg_lower_expr.lowerExpr(self, fs, e.cond)) orelse return null;
    const track = try cfg_lower_emit.beginCond(self, fs, e.span);
    const then_block = try cfg_lower_emit.newBlock(self, fs, "then");
    const else_block = try cfg_lower_emit.newBlock(self, fs, "else");
    try cfg_lower_emit.setTerminator(self, fs, .{ .br = .{ .cond = cond, .then_ = then_block, .else_ = else_block } });
    const join = try cfg_lower_emit.newBlock(self, fs, "join");

    // Then branch.
    fs.cur = then_block;
    const then_val = try cfg_lower_func.lowerBlock(self, fs, e.then);
    // The phi input's predecessor is the block that actually branches
    // to the join — for a nested then (`if (a) { if (b) { … } }`) that
    // is the inner join, not then_block.
    const then_pred = fs.cur;
    const then_liv = try cfg_lower_emit.condLiveness(self, fs, track);
    if (then_pred != null) try cfg_lower_emit.setTerminator(self, fs, .{ .j = join });
    cfg_lower_emit.restoreCond(self, fs, track);

    // Else branch: a block / nested if, or void when absent (Core
    // §13.2 — without `else` the expression is void).
    fs.cur = else_block;
    const else_val = if (e.else_) |el|
        try cfg_lower_expr.lowerExpr(self, fs, el)
    else
        try cfg_lower_expr.emitVoid(self, fs, e.span);
    const else_pred = fs.cur;
    const else_liv = try cfg_lower_emit.condLiveness(self, fs, track);
    if (else_pred != null) try cfg_lower_emit.setTerminator(self, fs, .{ .j = join });
    cfg_lower_emit.restoreCond(self, fs, track);

    // @intFromBool yields u1; widen before summing so two completing
    // branches don't overflow (Debug builds panic on u1 + u1 = 2).
    const completing = @as(u2, @intFromBool(then_val != null)) + @as(u2, @intFromBool(else_val != null));
    if (completing == 0) {
        // Every branch trapped: the join is unreachable. Keep it as a
        // trap-terminated dead block (see `trapUnreachableJoin`) rather
        // than popping "the last block" — a nested trapped branch may
        // have created blocks after the join, and popping those instead
        // of the join left it with an undefined terminator.
        try trapUnreachableJoin(self, fs, join);
        return null;
    }
    fs.cur = join;
    try cfg_lower_emit.joinMaybeFlags(self, fs, track, e.span, &.{
        .{ .pred = then_pred, .released = then_liv, .out_val = then_val },
        .{ .pred = else_pred, .released = else_liv, .out_val = else_val },
    });
    return try makeJoinPhi(self, fs, join, e.span, &.{
        .{ .v = then_val, .b = then_pred orelse then_block },
        .{ .v = else_val, .b = else_pred orelse else_block },
    });
}

pub fn lowerMatch(self: *Lowerer, fs: *FuncState, e: *const ast.MatchExpr) LowerError!?*cfg.Value {
    const moving = isMoveExpr(e.scrutinee);
    const scrut = (try cfg_lower_expr.lowerExpr(self, fs, e.scrutinee)) orelse return null;
    if (scrut.type_ == .named) {
        if (self.resolve.typeNameOf(scrut.type_.named.id)) |tname| {
            if (moduleinfo.unionDecl(self.resolve, fs.module, tname)) |ud| {
                return try lowerUnionMatch(self, fs, e, scrut, moving, ud);
            }
        }
    }
    return try lowerPatternMatch(self, fs, e, scrut, moving);
}

/// A union match: `read_tag` + `switch` over the variant
/// discriminants; per-arm payload binds; join phi (air.md §14.3).
pub fn lowerUnionMatch(
    self: *Lowerer,
    fs: *FuncState,
    e: *const ast.MatchExpr,
    scrut: *cfg.Value,
    moving: bool,
    ud: *const ast.UnionDef,
) LowerError!?*cfg.Value {
    const tag = (try cfg_lower_emit.emit(self, fs, e.span, .{ .read_tag = scrut }, .{ .primitive = .uint32 })).?;
    // `match (move s)` transfers the whole owner (Core §13.4); the
    // consumption is reflected before `beginCond`, so the scrutinee is
    // not tracked as a maybe-unique candidate.
    if (moving) cfg_lower_emit.markConsumed(self, fs, scrut);
    const track = try cfg_lower_emit.beginCond(self, fs, e.span);

    // First-match-wins coverage (Core §13.3): a variant arm covers its
    // tag; a wildcard/identifier arm is a catch-all covering every tag
    // not yet covered; any arm after the first catch-all is dead.
    const cover_arm = try self.arena.alloc(?usize, ud.variants.len);
    @memset(cover_arm, null);
    var catchall: ?usize = null; // the first catch-all arm's index, if any
    const live = try self.arena.alloc(bool, e.arms.len);
    @memset(live, false);
    for (e.arms, 0..) |*arm, i| {
        if (catchall != null) continue; // already fully covered: dead
        if (armIsCatchAll(&arm.pattern)) {
            live[i] = true;
            catchall = i;
            continue;
        }
        const vtag = try armVariantTag(self, fs, ud, &arm.pattern, arm.span);
        if (cover_arm[vtag] != null) continue; // duplicate variant: dead
        cover_arm[vtag] = i;
        live[i] = true;
    }

    // One arm block per live arm; every tag dispatches to the first
    // arm that covers it. Uncovered tags trap (match exhaustiveness is
    // checked in phase 2; the trap is the backstop).
    var arm_blocks = std.ArrayList(*cfg.BasicBlock).empty;
    const block_of = try self.arena.alloc(?*cfg.BasicBlock, e.arms.len);
    @memset(block_of, null);
    for (e.arms, 0..) |*arm, i| {
        _ = arm;
        if (!live[i]) continue;
        const ab = try cfg_lower_emit.newBlock(self, fs, try cfg_lower_emit.fmtBlockName(self, "arm", i));
        try arm_blocks.append(self.arena, ab);
        block_of[i] = ab;
    }
    var arms = std.ArrayList(cfg.SwitchArm).empty;
    for (ud.variants, 0..) |_, ti| {
        const b = if (cover_arm[ti]) |i| block_of[i].? else if (catchall) |i| block_of[i].? else continue;
        try arms.append(self.arena, .{ .tag = @intCast(ti), .block = b });
    }
    try cfg_lower_emit.setTerminator(self, fs, .{ .@"switch" = .{ .disc = tag, .arms = arms.items } });
    const join = try cfg_lower_emit.newBlock(self, fs, "join");
    var incoming = std.ArrayList(JoinIn).empty;
    var branches = std.ArrayList(cfg_lower_emit.CondBranch).empty;
    for (e.arms, 0..) |*arm, i| {
        if (!live[i]) continue;
        const ab = block_of[i].?;
        fs.cur = ab;
        try fs.scopes.append(self.arena, .{});
        try bindUnionPattern(self, fs, &arm.pattern, scrut, moving);
        const v = try cfg_lower_expr.lowerExpr(self, fs, arm.body);
        try cfg_lower_emit.exitScope(self, fs, v);
        // The phi input's predecessor is the block that actually
        // branches to the join (the inner join for a nested arm body).
        const pred = fs.cur orelse ab;
        try incoming.append(self.arena, .{ .v = v, .b = pred });
        const arm_liv = try cfg_lower_emit.condLiveness(self, fs, track);
        try branches.append(self.arena, .{ .pred = fs.cur, .released = arm_liv, .out_val = v });
        if (fs.cur != null) try cfg_lower_emit.setTerminator(self, fs, .{ .j = join });
        cfg_lower_emit.restoreCond(self, fs, track);
    }
    var completing: usize = 0;
    for (incoming.items) |inc| {
        if (inc.v != null) completing += 1;
    }
    if (completing == 0) {
        // Every arm trapped: the join is unreachable; keep it as a
        // trap-terminated dead block (see `trapUnreachableJoin`).
        try trapUnreachableJoin(self, fs, join);
        return null;
    }
    fs.cur = join;
    try cfg_lower_emit.joinMaybeFlags(self, fs, track, e.span, branches.items);
    return try makeJoinPhi(self, fs, join, e.span, incoming.items);
}

/// True when a union-match arm pattern is a catch-all: `_` or a plain
/// identifier (no variant tail).
/// The number of test conditions an arm's pattern needs: literal and
/// type-test arms test once; list patterns test length plus one equality
/// per literal item; everything else is irrefutable and tested nowhere.
fn armTestCount(p: *const ast.Pattern) usize {
    return switch (p.*) {
        .literal, .type_test => 1,
        .list => |lp| blk: {
            var n: usize = 1; // the length test
            for (lp.items) |*it| {
                if (it.* == .literal) n += 1;
            }
            break :blk n;
        },
        else => 0,
    };
}

/// Whether the arm's pattern has a test condition at index `k`.
fn hasArmTest(self: *Lowerer, fs: *FuncState, arm: *const ast.MatchArm, k: usize) LowerError!bool {
    _ = self;
    _ = fs;
    return k < armTestCount(&arm.pattern);
}

/// Emit the k-th test condition for a match arm; null when the pattern
/// has no test at that index. List patterns test length first (k == 0),
/// then each literal item's equality (k == 1 + literal index).
fn emitArmTest(self: *Lowerer, fs: *FuncState, scrut: *cfg.Value, arm: *const ast.MatchArm, k: usize) LowerError!?*cfg.Value {
    const span = arm.span;
    switch (arm.pattern) {
        .literal => |lp| {
            if (k != 0) return null;
            const lit = try cfg_lower_pattern.lowerLiteralConst(self, fs, &lp);
            return try cfg_lower_emit.emit(self, fs, span, .{ .eq = .{ .a = scrut, .b = lit } }, .{ .primitive = .bool });
        },
        .type_test => |tp| {
            if (k != 0) return null;
            const test_type = try self.resolveType(fs, &tp.type_);
            return try cfg_lower_emit.emit(self, fs, tp.span, .{ .type_is = .{ .value = scrut, .type_ = test_type } }, .{ .primitive = .bool });
        },
        .list => |lp| {
            if (k == 0) {
                // Length test: `[a, b]` matches only length-2 lists;
                // `[a, ..t]` matches lists of length >= 1 (Core §14.5).
                const target: i64 = @intCast(lp.items.len);
                const n_const = (try cfg_lower_expr.emitConst(self, fs, span, .{ .int = target }, .{ .primitive = .int32 })).?;
                const len_args = try self.arena.alloc(*cfg.Value, 1);
                len_args[0] = scrut;
                // The length query is the `list.len` intrinsic's
                // host-backed expansion (Runtime §4.3) — the same
                // `list#len` syscall a source `list.len(xs)` call lowers
                // to, derived from the single expansion table
                // (`cfg_lower_intrinsic.syscallTarget`), so list-pattern
                // matches and explicit length queries dispatch
                // identically. The syscall carries the specialized
                // signature `fn len[T](borrow xs: list[T]) -> int32`
                // (air.md §8.2).
                const elem_type = switch (scrut.type_) {
                    .list => |inner| inner.*,
                    else => return self.fail(span, "list pattern requires a list value", .{}),
                };
                const elem_ptr = try self.arena.create(cfg.Type);
                elem_ptr.* = elem_type;
                const len_params = try self.arena.alloc(cfg.Param, 1);
                len_params[0] = cfg.syntheticParam(span, .borrow, .{ .list = elem_ptr });
                const len_ret = try self.arena.create(cfg.Type);
                len_ret.* = .{ .primitive = .int32 };
                const len = (try cfg_lower_emit.emit(self, fs, span, .{ .syscall = .{ .span = span, .target = try cfg_lower_intrinsic.intrinsicSyscallTarget(self, span, "list", "len"), .args = len_args, .sig = .{ .params = len_params, .ret = len_ret } } }, .{ .primitive = .int32 })).?;
                if (lp.rest != null) {
                    return try cfg_lower_emit.emit(self, fs, span, .{ .ge = .{ .a = len, .b = n_const } }, .{ .primitive = .bool });
                }
                return try cfg_lower_emit.emit(self, fs, span, .{ .eq = .{ .a = len, .b = n_const } }, .{ .primitive = .bool });
            }
            // Item test: the (k-1)-th literal item's equality with the
            // scrutinee element at its index.
            const elem_type = switch (scrut.type_) {
                .list => |inner| inner.*,
                else => return self.fail(span, "list pattern requires a list value", .{}),
            };
            var item_idx: usize = 0;
            var lit_idx: usize = 1;
            for (lp.items) |*it| {
                if (it.* != .literal) {
                    item_idx += 1;
                    continue;
                }
                if (lit_idx == k) {
                    const lit = try cfg_lower_pattern.lowerLiteralConst(self, fs, &it.*.literal);
                    const idx = (try cfg_lower_expr.emitConst(self, fs, span, .{ .int = @intCast(item_idx) }, .{ .primitive = .int32 })).?;
                    const elem = (try cfg_lower_emit.emit(self, fs, span, .{ .read_index = .{ .base = scrut, .index = idx } }, elem_type)).?;
                    return try cfg_lower_emit.emit(self, fs, span, .{ .eq = .{ .a = elem, .b = lit } }, .{ .primitive = .bool });
                }
                item_idx += 1;
                lit_idx += 1;
            }
            return null;
        },
        else => return null,
    }
}

fn armIsCatchAll(p: *const ast.Pattern) bool {
    return switch (p.*) {
        .wildcard => true,
        .path => |pp| pp.tail == .none,
        else => false,
    };
}

/// The union variant tag an arm's pattern selects (a variant
/// pattern, Core §11.1). Refutable arms are the only supported form
/// in a union match for now.
pub fn armVariantTag(self: *Lowerer, fs: *FuncState, ud: *const ast.UnionDef, pattern: *const ast.Pattern, span: ast.Span) LowerError!u32 {
    _ = fs;
    switch (pattern.*) {
        .path => |pp| switch (pp.tail) {
            .variant => |vp| {
                return moduleinfo.variantIndex(ud, vp.name.text) orelse
                    self.fail(vp.name.span, "union has no variant '{s}'", .{vp.name.text});
            },
            else => {},
        },
        else => {},
    }
    return self.fail(span, "unsupported pattern in a union match (expected a variant pattern or a catch-all)", .{});
}

/// Bind the patterns of a union-match arm: a variant pattern binds
/// its payload (`unpack_variant` for a consuming match — one atomic op
/// defines the variant's payload values, tag-carrying for backend
/// self-containment, air.md §5.3 — `read_payload` otherwise); an
/// identifier pattern binds the whole scrutinee (borrowed for a
/// non-consuming match, Core §13.4).
pub fn bindUnionPattern(self: *Lowerer, fs: *FuncState, pattern: *const ast.Pattern, scrut: *cfg.Value, moving: bool) LowerError!void {
    switch (pattern.*) {
        .wildcard => {},
        .path => |pp| switch (pp.tail) {
            .variant => |vp| {
                const ud = moduleinfo.unionDecl(self.resolve, fs.module, self.resolve.typeNameOf(scrut.type_.named.id) orelse unreachable).?;
                const tag = moduleinfo.variantIndex(ud, vp.name.text) orelse unreachable;
                const variant = ud.variants[tag];
                const args = vp.args orelse return; // no payload to bind
                const types = variant.types orelse return;
                if (types.len == 1) {
                    // The payload type of a generic instantiation
                    // substitutes the declaration's type parameters
                    // (Core §12.1): `Option[int32]`'s `Some` payload is
                    // `int32`, not `T`.
                    const payload_type = type_resolve.substParams(self.arena, ud.type_params, scrut.type_.named.args, try self.resolveType(fs, &types[0]));
                    if (moving) {
                        const payload = (try cfg_lower_emit.emitUnpack(self, fs, vp.name.span, .{ .unpack_variant = .{ .base = scrut, .tag = @intCast(tag) } }, &.{payload_type}))[0];
                        if (args.len == 1) {
                            try cfg_lower_pattern.bindPattern(self, fs, &args[0], payload, payload.state == .owned);
                        } else {
                            return self.fail(vp.name.span, "variant '{s}' has a single payload; expected one pattern", .{vp.name.text});
                        }
                    } else {
                        const payload = (try cfg_lower_emit.emit(self, fs, vp.name.span, .{ .read_payload = scrut }, payload_type)) orelse return;
                        if (args.len == 1) {
                            try cfg_lower_pattern.bindPattern(self, fs, &args[0], payload, payload.state == .owned);
                        } else {
                            return self.fail(vp.name.span, "variant '{s}' has a single payload; expected one pattern", .{vp.name.text});
                        }
                    }
                } else {
                    // A tuple payload destructures element-wise: one
                    // `unpack_variant` defines every payload element.
                    var payload_elems = std.ArrayList(cfg.Type).empty;
                    for (types) |*t| try payload_elems.append(self.arena, type_resolve.substParams(self.arena, ud.type_params, scrut.type_.named.args, try self.resolveType(fs, t)));
                    if (moving) {
                        const payloads = try cfg_lower_emit.emitUnpack(self, fs, vp.name.span, .{ .unpack_variant = .{ .base = scrut, .tag = @intCast(tag) } }, payload_elems.items);
                        for (args, payloads) |*argp, proj| try cfg_lower_pattern.bindPattern(self, fs, argp, proj, proj.state == .owned);
                    } else {
                        const payloads = try cfg_lower_emit.emitBorrowVariant(self, fs, vp.name.span, scrut, @intCast(tag), payload_elems.items);
                        for (args, payloads) |*argp, proj| try cfg_lower_pattern.bindPattern(self, fs, argp, proj, proj.state == .owned);
                    }
                }
            },
            .none => {
                // Identifier pattern binds the whole scrutinee.
                try cfg_lower_emit.bindLocal(self, fs, pp.path[pp.path.len - 1].text, scrut, moving and scrut.ownership == .unique and scrut.state == .owned);
            },
            else => return self.fail(pp.span, "unsupported pattern shape in a union match", .{}),
        },
        else => return self.fail(pattern.span(), "unsupported pattern in a union match", .{}),
    }
}

/// A non-union match: literal arms become `eq` tests and type-test
/// arms become `type_is` tests; the first arm that is neither (or the
/// last arm) is the fallthrough (air.md §14.3: `_`, literal, tuple,
/// struct, and list patterns lower to the same primitives; Core
/// §11.6.2 type-test patterns test the runtime tag of an `any`).
pub fn lowerPatternMatch(self: *Lowerer, fs: *FuncState, e: *const ast.MatchExpr, scrut: *cfg.Value, moving: bool) LowerError!?*cfg.Value {
    // A match over an `any` value with type-test patterns must include
    // a wildcard arm: the tag space is open, so the patterns cannot be
    // exhaustive without it (Core §11.6.2).
    var has_type_test = false;
    for (e.arms) |*arm| {
        if (cfg_lower_pattern.patternHasTypeTest(&arm.pattern)) {
            has_type_test = true;
            break;
        }
    }
    if (has_type_test) {
        var has_wildcard = false;
        for (e.arms) |*arm| if (arm.pattern == .wildcard) {
            has_wildcard = true;
            break;
        };
        if (!has_wildcard) {
            return self.fail(e.span, "a match over an 'any' value with type-test patterns must include a wildcard '_' arm", .{});
        }
        // A type-test pattern nested inside a tuple/list/struct pattern
        // would recover a payload without a preceding `type_is` test;
        // only whole-arm type-test patterns carry their own test (Core
        // §14.7: the pattern is a concrete type name, optionally
        // followed by a binding).
        for (e.arms) |*arm| {
            if (arm.pattern != .type_test and cfg_lower_pattern.patternHasTypeTest(&arm.pattern)) {
                return self.fail(arm.span, "a type-test pattern must be the whole arm of a match", .{});
            }
        }
    }
    const track = try cfg_lower_emit.beginCond(self, fs, e.span);
    const n = e.arms.len;
    var arm_blocks = std.ArrayList(*cfg.BasicBlock).empty;
    for (e.arms, 0..) |*arm, i| {
        _ = arm;
        try arm_blocks.append(self.arena, try cfg_lower_emit.newBlock(self, fs, try cfg_lower_emit.fmtBlockName(self, "arm", i)));
    }
    // Fallthrough: the first arm that is not refutable — a literal, a
    // type-test pattern, or a list pattern that constrains the value
    // (`[]` needs an emptiness test, `[a, b]` a length + element test,
    // `[h, ..t]` a length >= 1 test so the bindings never read out of
    // bounds). Only a `[..rest]` list pattern (no items) and the other
    // irrefutable shapes (struct/tuple/identifier/wildcard) fall
    // through. Else the last arm.
    var fallthrough: usize = n - 1;
    for (e.arms, 0..) |*arm, i| switch (arm.pattern) {
        .literal, .type_test => {},
        .list => |lp| {
            // `[]` and item-bearing patterns are refutable (length and
            // element tests); only `[..rest]` matches any list.
            if (lp.items.len == 0 and lp.rest != null) {
                fallthrough = i;
                break;
            }
        },
        else => {
            fallthrough = i;
            break;
        },
    };
    // Tests: literal arms become `eq` + br, type-test arms become
    // `type_is` + br, list patterns become a length test followed
    // by per-literal-item `eq` tests (`[1, 2]` matches only length-2
    // lists whose elements equal 1 and 2; `[h, ..t]` requires len >= 1
    // so the bindings never read out of bounds), chained in the
    // scrutinee's block: every condition of an arm must hold for the arm
    // to match, and any failure falls through to the next arm's test.
    var cur_test = fs.cur orelse return null;
    var i: usize = 0;
    while (i < n and i != fallthrough) : (i += 1) {
        const next_test: *cfg.BasicBlock = if (i + 1 == fallthrough) arm_blocks.items[fallthrough] else blk: {
            const nb = try cfg_lower_emit.newBlock(self, fs, "test");
            break :blk nb;
        };
        var cond_block = cur_test;
        var k: usize = 0;
        while (true) : (k += 1) {
            fs.cur = cond_block;
            const cond = (try emitArmTest(self, fs, scrut, &e.arms[i], k)) orelse break;
            const has_next = try hasArmTest(self, fs, &e.arms[i], k + 1);
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
    for (e.arms, arm_blocks.items) |*arm, ab| {
        fs.cur = ab;
        try fs.scopes.append(self.arena, .{});
        try cfg_lower_pattern.bindPattern(self, fs, &arm.pattern, scrut, moving);
        const v = try cfg_lower_expr.lowerExpr(self, fs, arm.body);
        try cfg_lower_emit.exitScope(self, fs, v);
        // The phi input's predecessor is the block that actually
        // branches to the join (the inner join for a nested arm body).
        const pred = fs.cur orelse ab;
        try incoming.append(self.arena, .{ .v = v, .b = pred });
        const arm_liv = try cfg_lower_emit.condLiveness(self, fs, track);
        try branches.append(self.arena, .{ .pred = fs.cur, .released = arm_liv, .out_val = v });
        if (fs.cur != null) try cfg_lower_emit.setTerminator(self, fs, .{ .j = join });
        cfg_lower_emit.restoreCond(self, fs, track);
    }
    var completing: usize = 0;
    for (incoming.items) |inc| {
        if (inc.v != null) completing += 1;
    }
    if (completing == 0) {
        // Every arm trapped: the join is unreachable; keep it as a
        // trap-terminated dead block (see `trapUnreachableJoin`).
        try trapUnreachableJoin(self, fs, join);
        return null;
    }
    fs.cur = join;
    try cfg_lower_emit.joinMaybeFlags(self, fs, track, e.span, branches.items);
    return try makeJoinPhi(self, fs, join, e.span, incoming.items);
}
