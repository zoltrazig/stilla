//! Pass: CFG emission and function-state support (ir.md §4, §6.1–§6.4).
//! In: Lowerer + per-function FuncState (blocks under construction, value
//! table, symbol table, scope stack, ownership bookkeeping).
//! Out: instructions, values, blocks, phi builders, scope-end drops, and the
//! block/value naming primitives every lowering pass builds on.
//!
//! `emit` — the IR node constructor — also performs the **on-the-fly
//! optimizations** of braun13cc.pdf §3.1 at each construction site:
//! constant folding and arithmetic simplification (a pure op over
//! constants or integer identities folds to the constant / operand),
//! common subexpression elimination (an identical pure computation
//! earlier in the same block is reused), and copy propagation (a `copy`
//! of a Copy value is the value itself). The frontend therefore
//! needs no separate passes for these (frontend.md §4.3); partial
//! redundancy elimination, dead-block elimination, drop elision, jump
//! threading, and phi simplification still run as the Pass 8 sequence
//! over the finished program.

const std = @import("std");
const ast = @import("../ast.zig");
const cfg = @import("../cfg.zig");
const moduleinfo = @import("../moduleinfo.zig");
const lower = @import("../lower.zig");

const FuncState = lower.FuncState;

/// The resolved ownership of a type (named types resolve through the
/// module graph); `null` (unspecialized) is treated as Copy.
pub fn ownership(self: *lower.Lowerer, fs: *lower.FuncState, type_: cfg.Type) ?cfg.Ownership {
    return moduleinfo.ownershipOf(self.resolve, fs.module, type_);
}

pub fn isUnique(self: *lower.Lowerer, fs: *lower.FuncState, type_: cfg.Type) bool {
    return (ownership(self, fs, type_) orelse cfg.Ownership.copy) == .unique;
}

/// True when the value must not silently leak: resolved-unique, or a
/// deferred (generic) ownership that monomorphization may resolve to
/// unique. Used by the exact-pattern `split_list` remainder drop.
pub fn mayBeUnique(self: *lower.Lowerer, fs: *lower.FuncState, type_: cfg.Type) bool {
    return (ownership(self, fs, type_) orelse cfg.Ownership.unique) == .unique;
}

pub fn isVoid(t: cfg.Type) bool {
    return switch (t) {
        .primitive => |k| k == .void,
        else => false,
    };
}

pub fn isNever(t: cfg.Type) bool {
    return switch (t) {
        .primitive => |k| k == .never,
        else => false,
    };
}

/// Emit one instruction. When `result_type` is non-null the
/// instruction defines a fresh value (tracked for scope-end drops
/// when unique-owned); null makes it a pure effect (`drop`,
/// `store_member`, void/never calls). Returns null when the current
/// block is terminated (dead code — no-op).
pub fn emit(
    self: *lower.Lowerer,
    fs: *lower.FuncState,
    span: ast.Span,
    op: cfg.Op,
    result_type: ?cfg.Type,
) lower.LowerError!?*cfg.Value {
    const b = fs.cur orelse return null;
    var op2 = op;
    if (result_type) |rt| {
        // On-the-fly optimization (braun13cc.pdf §3.1): each instruction
        // is simplified at its construction site, so the frontend needs
        // no separate folding / simplification / CSE / copy-propagation
        // passes (frontend.md §4.3). Order: fold, then copy elision,
        // then arithmetic simplification, then CSE.
        if (tryFoldOp(op2, rt)) |c| {
            // Constant folding: a pure op over constants becomes the
            // constant (trap-preserving — see `tryFoldOp`).
            op2 = .{ .const_ = c };
        } else if (op2 == .copy) {
            // Copy propagation: a `copy` of a Copy value is the
            // value itself (ir.md §5.4). Unique copies are illegal and
            // deferred-ownership copies are kept (matching the old copy
            // propagation pass's leave-deferred-copies-alone rule).
            if (ownership(self, fs, op2.copy.type_) == .copy) return op2.copy;
        } else if (simplifyOp(op2, rt)) |simp| {
            // Arithmetic simplification: integer identities only (float
            // identities are unsound — x−x ≠ 0 for NaN, 0·x ≠ 0 for
            // ±inf/NaN, 0+x ≠ x for −0.0).
            switch (simp) {
                .reuse => |v| return v,
                .const_ => |c| op2 = .{ .const_ = c },
                .none => {},
            }
        } else if (ownership(self, fs, rt) == .copy) {
            if (findCse(fs, b, op2)) |canonical| {
                // CSE: reuse an identical pure computation earlier in
                // the same block — its result dominates every later use.
                return canonical;
            }
        }
    }
    var result: ?*cfg.Value = null;
    if (result_type) |rt| {
        const v = try newValue(self, fs, span, rt, createdState(op2, fs, rt));
        if (v.state == .borrowed) v.origin = cfg.originOf(op2);
        result = v;
        if (v.ownership == .unique) try fs.created.append(self.arena, v);
    }
    const instr = try self.arena.create(cfg.Instr);
    if (result) |v| {
        const results = try self.arena.alloc(*cfg.Value, 1);
        results[0] = v;
        instr.* = .{ .span = span, .results = results, .op = op2 };
        v.def = instr;
    } else {
        instr.* = .{ .span = span, .results = &.{}, .op = op2 };
    }
    try fs.block_instrs.items[b.id].append(self.arena, instr);
    return result;
}

/// Emit an atomic destructure op (ir.md §5.3): one instruction consumes
/// `base` as a whole and defines all of its parts at once, with
/// consecutive ids in the value table. Every unique result is tracked
/// for scope-end destruction exactly like an `emit` result. The op's
/// base-operand consumption is validated by `cfg.validate`; the
/// lowering additionally calls `markConsumed` / `cleanupDisable` on the
/// base so the checker-side binding state stays in sync.
pub fn emitUnpack(self: *lower.Lowerer, fs: *lower.FuncState, span: ast.Span, op: cfg.Op, result_types: []const cfg.Type) lower.LowerError![]*cfg.Value {
    const b = fs.cur orelse return &.{};
    const results = try self.arena.alloc(*cfg.Value, result_types.len);
    for (result_types, 0..) |rt, i| {
        const v = try newValue(self, fs, span, rt, .owned);
        results[i] = v;
        if (v.ownership == .unique) try fs.created.append(self.arena, v);
    }
    const instr = try self.arena.create(cfg.Instr);
    instr.* = .{ .span = span, .results = results, .op = op };
    try fs.block_instrs.items[b.id].append(self.arena, instr);
    for (results) |v| v.def = instr;
    return results;
}

/// The created value state of a definition (ir.md §6.1): from the op
/// schema for the static cases, or derived from the operand for the
/// `.operand` ops (projections whose created state follows the
/// *result* type — a Copy member read from an unique base is a copy,
/// an unique member read is a borrowed view). Parameters are SSA roots
/// (ir.md §5.1): their state is set when they are seeded, never by an op.
pub fn createdState(op: cfg.Op, fs: *lower.FuncState, result_type: cfg.Type) cfg.ValueState {
    _ = fs;
    return switch (cfg.opInfo(std.meta.activeTag(op)).created) {
        .owned => .owned,
        .borrowed => .borrowed,
        .none => .owned, // effects produce no value; unreachable here
        .operand => switch (op) {
            .read_field, .read_tuple, .read_index, .read_payload => readState(result_type),
            .tail => |v| readState(v.type_),
            else => unreachable,
        },
    };
}

pub fn readState(t: cfg.Type) cfg.ValueState {
    const ow = t.ownership();
    return if (ow == null or ow.? == .unique) .borrowed else .owned;
}

// -----------------------------------------------------------------
// Ownership bookkeeping
// -----------------------------------------------------------------

pub fn markConsumed(self: *lower.Lowerer, fs: *lower.FuncState, v: *cfg.Value) void {
    fs.consumed.put(self.arena, v, {}) catch {};
}

pub fn isConsumed(fs: *lower.FuncState, v: *cfg.Value) bool {
    return fs.consumed.contains(v);
}

/// Emit an instruction into a specific block — used to materialize the
/// `T → any` coercion of a phi input on its predecessor edge (ir.md
/// §4.4), where the branch block is already terminated, and the
/// `cleanup_disable` of a token whose owner was consumed on that edge.
/// The instruction is appended after the block's existing instructions
/// (immediately before its terminator), which is the correct evaluation
/// point. No on-the-fly folding/CSE applies (these ops are not foldable
/// or shareable).
pub fn emitInto(self: *lower.Lowerer, fs: *lower.FuncState, b: *cfg.BasicBlock, span: ast.Span, op: cfg.Op, result_type: ?cfg.Type) lower.LowerError!?*cfg.Value {
    var result: ?*cfg.Value = null;
    if (result_type) |rt| {
        const v = try newValue(self, fs, span, rt, createdState(op, fs, rt));
        if (v.state == .borrowed) v.origin = cfg.originOf(op);
        result = v;
        if (v.ownership == .unique) try fs.created.append(self.arena, v);
    }
    const instr = try self.arena.create(cfg.Instr);
    if (result) |v| {
        const results = try self.arena.alloc(*cfg.Value, 1);
        results[0] = v;
        instr.* = .{ .span = span, .results = results, .op = op };
        v.def = instr;
    } else {
        instr.* = .{ .span = span, .results = &.{}, .op = op };
    }
    try fs.block_instrs.items[b.id].append(self.arena, instr);
    return result;
}

/// Disarm `v`'s cleanup token after an ownership transfer on the current
/// path — a `move`, an atomic `unpack_*` / `split_list` destructure, a
/// move-mode call argument, a phi input, a `ret`, or an unique element
/// moved into a `construct`.
/// The payload is not destroyed here (it transferred); the token must
/// simply not destroy it at scope end. No-op when `v` has no token (it
/// was never a conditional-release candidate, ir.md §6.4).
pub fn cleanupDisable(self: *lower.Lowerer, fs: *lower.FuncState, span: ast.Span, v: *cfg.Value) lower.LowerError!void {
    const b = fs.cur orelse return;
    return cleanupDisableInto(self, fs, b, span, v);
}

/// `cleanupDisable` into a specific block (a branch edge or the join).
pub fn cleanupDisableInto(self: *lower.Lowerer, fs: *lower.FuncState, b: *cfg.BasicBlock, span: ast.Span, v: *cfg.Value) lower.LowerError!void {
    if (fs.cleanup_tokens.get(v)) |tok| {
        _ = try emitInto(self, fs, b, span, .{ .cleanup_disable = tok }, null);
    }
}

/// Drop a value (a `drop` effect); the value is dead afterwards.
/// Dropping a Copy value does nothing (Core §10.1). A value with a
/// cleanup token — a conditional-release candidate (Core §10.10) — is
/// destroyed through its token: `drop_cleanup` destroys the payload iff
/// the token is still armed (the value was not consumed on this path),
/// then disarms it. The maybe-unique *value* itself is never referenced
/// after the construct's join (ir.md §6.4).
pub fn emitDrop(self: *lower.Lowerer, fs: *lower.FuncState, span: ast.Span, v: *cfg.Value) lower.LowerError!void {
    if (!isUnique(self, fs, v.type_)) return;
    // Borrowed values are views (borrow params, `borrow` ops,
    // projections of an unique base) and are never drop candidates
    // (Core §9.2 destruction view; ir.md §6.4).
    if (v.state == .borrowed) return;
    if (isConsumed(fs, v)) return;
    if (fs.cleanup_tokens.get(v)) |tok| {
        _ = try emit(self, fs, span, .{ .drop_cleanup = tok }, null);
        markConsumed(self, fs, v);
        return;
    }
    _ = try emit(self, fs, span, .{ .drop_ = v }, null);
    markConsumed(self, fs, v);
}

/// Drop the unique-owned temporaries created since `start` (reverse
/// creation order, Runtime §6.4), skipping the expression result and
/// anything already consumed.
pub fn dropCreatedRange(self: *lower.Lowerer, fs: *lower.FuncState, start: usize, except: ?*cfg.Value) lower.LowerError!void {
    var i = fs.created.items.len;
    while (i > start) {
        i -= 1;
        const v = fs.created.items[i];
        if (v == except) continue;
        if (isConsumed(fs, v)) continue;
        try emitDrop(self, fs, v.span, v);
    }
}

pub fn bindLocal(self: *lower.Lowerer, fs: *lower.FuncState, name: []const u8, value: *cfg.Value, owns_unique: bool) lower.LowerError!void {
    if (fs.scopes.items.len == 0) try fs.scopes.append(self.arena, .{});
    const local = try self.arena.create(lower.Local);
    local.* = .{ .name = name, .value = value, .owns_unique = owns_unique };
    try fs.scopes.items[fs.scopes.items.len - 1].locals.append(self.arena, local);
    try fs.symbols.put(self.arena, name, local);
    try fs.local_values.put(self.arena, value, {});
    if (owns_unique) try fs.value_locals.put(self.arena, value, local);
}

pub fn lookupLocal(fs: *lower.FuncState, name: []const u8) ?*lower.Local {
    return fs.symbols.get(name);
}

/// Scope end: drop every live unique-owned local in reverse creation
/// order, except the value flowing out of the scope (ir.md §6.4).
pub fn exitScope(self: *lower.Lowerer, fs: *lower.FuncState, except: ?*cfg.Value) lower.LowerError!void {
    if (fs.scopes.items.len == 0) return;
    const scope = &fs.scopes.items[fs.scopes.items.len - 1];
    var i = scope.locals.items.len;
    while (i > 0) {
        i -= 1;
        const local = scope.locals.items[i];
        if (local.value == except) continue;
        if (local.owns_unique and !local.consumed) {
            try emitDrop(self, fs, local.value.span, local.value);
            local.consumed = true;
        }
    }
    _ = fs.scopes.pop();
}

// -----------------------------------------------------------------
// Conditional-release bookkeeping (Core §10.10, ir.md §6.4)
// -----------------------------------------------------------------

/// The tracked bindings of a conditional construct: the live unique
/// owners that might be consumed on some but not all paths through it.
/// Each candidate is given a cleanup token at the construct's entry; a
/// consuming path disarms it (`cleanup_disable`), and the scope-end
/// destruction is a `drop_cleanup` of the token — destroying the payload
/// iff it was never transferred on the path that reached the scope exit.
pub const CondTrack = struct {
    candidates: []*cfg.Value,
};

/// One completed branch of a conditional construct: its in-edge
/// predecessor (`null` when the branch trapped — it contributes no edge
/// to the join) and, per candidate, whether that edge released the value.
pub const CondBranch = struct {
    pred: ?*cfg.BasicBlock,
    released: []bool,
};

/// Snapshot the unique bindings visible at a conditional construct's
/// entry (Core §10.10): every live, owned, unique value bound to a local
/// at the current point, in value-id order. Each candidate that does not
/// already have a token gets one now — a `cleanup_owner` in the current
/// block, which dominates every branch and the join, so the token is
/// armed on every path until a consuming path disarms it. Call after the
/// condition/scrutinee has been lowered — a binding consumed there is
/// already dead and excluded. Returns an empty track when no binding can
/// be released on one branch but not another.
pub fn beginCond(self: *lower.Lowerer, fs: *lower.FuncState, span: ast.Span) lower.LowerError!CondTrack {
    var cands = std.ArrayListUnmanaged(*cfg.Value).empty;
    for (fs.values.items) |v| {
        if (v.ownership == .unique and v.state == .owned and !isConsumed(fs, v) and fs.local_values.contains(v)) {
            try cands.append(self.arena, v);
        }
    }
    if (cands.items.len == 0) {
        return .{ .candidates = &.{} };
    }
    for (cands.items) |v| {
        if (!fs.cleanup_tokens.contains(v)) {
            const tok = (try emit(self, fs, span, .{ .cleanup_owner = v }, .cleanup)).?;
            try fs.cleanup_tokens.put(self.arena, v, tok);
        }
    }
    return .{ .candidates = cands.items };
}

/// Record each tracked candidate's release on the current edge: true
/// once consumed on this branch, false otherwise.
pub fn condLiveness(self: *lower.Lowerer, fs: *lower.FuncState, track: CondTrack) lower.LowerError![]bool {
    const rel = try self.arena.alloc(bool, track.candidates.len);
    for (track.candidates, 0..) |v, i| {
        rel[i] = isConsumed(fs, v);
    }
    return rel;
}

/// Reset tracked candidates to their construct-entry state (alive, not
/// consumed) so each branch measures only its own consumption. Call
/// after capturing a branch's release vector, before lowering the next
/// branch. Cleanup tokens are *not* reset: they are per-value, created
/// once, and branch-local disarms must persist.
pub fn restoreCond(_: *lower.Lowerer, fs: *lower.FuncState, track: CondTrack) void {
    for (track.candidates) |v| {
        _ = fs.consumed.remove(v);
    }
}

/// Merge a conditional construct's branches at the join (Core §10.10).
/// A tracked binding consumed on every completing branch is definitely
/// released: its scope-end drop is skipped (the token is already
/// disarmed on every path). Consumed on some but not all branches, the
/// binding is *maybe-unique*: no join-time state exists — the token's
/// per-path armed bit *is* the conditional destruction, and the scope-end
/// `drop_cleanup` destroys the payload only on the paths that kept it.
/// The maybe-unique value itself has no uses after the join (ir.md §6.4).
pub fn joinMaybeFlags(
    self: *lower.Lowerer,
    fs: *lower.FuncState,
    track: CondTrack,
    _: ast.Span,
    branches: []const CondBranch,
) lower.LowerError!void {
    if (track.candidates.len == 0) return;
    for (track.candidates, 0..) |v, i| {
        var real: usize = 0;
        var all_released = true;
        for (branches) |b| {
            if (b.pred == null) continue;
            real += 1;
            if (!b.released[i]) all_released = false;
        }
        if (real == 0) continue; // every branch trapped; nothing to merge
        if (!all_released) {
            // Maybe-unique: the token handles the conditional destruction.
            // The local's consumed flag must stay clear so the scope-end
            // `drop_cleanup` is emitted (ir.md §6.4).
            if (fs.value_locals.get(v)) |l| l.consumed = false;
            continue;
        }
        // Released on every path: definitely consumed (ir.md §6.4
        // scope-end destruction skips it).
        markConsumed(self, fs, v);
        if (fs.value_locals.get(v)) |l| l.consumed = true;
    }
}

// -----------------------------------------------------------------
// Blocks and values
// -----------------------------------------------------------------

pub fn newBlock(self: *lower.Lowerer, fs: *lower.FuncState, name: []const u8) lower.LowerError!*cfg.BasicBlock {
    // Block labels must be unique within a function: the printed IR
    // text (ir.md §9) is re-parsed by the standalone cfg parser, which
    // rejects duplicate labels. The first block with a given base name
    // keeps it (stable text); later collisions get a numeric suffix
    // (two `if` joins, two `for` loops, multi-test matches, ...).
    var final_name = name;
    var n: u32 = 1;
    while (blockNameUsed(fs, final_name)) {
        final_name = try std.fmt.allocPrint(self.arena, "{s}_{d}", .{ name, n });
        n += 1;
    }
    const b = try self.arena.create(cfg.BasicBlock);
    b.* = .{
        .id = @intCast(fs.blocks.items.len),
        .span = ast.Span.init(0, 0, 0),
        .name = final_name,
        .instrs = &.{},
        .terminator = undefined,
        .preds = &.{},
    };
    try fs.blocks.append(self.arena, b);
    try fs.block_instrs.append(self.arena, .empty);
    return b;
}

pub fn setTerminator(_: *lower.Lowerer, fs: *lower.FuncState, term: cfg.Terminator) lower.LowerError!void {
    const b = fs.cur orelse return;
    b.terminator = term;
    fs.cur = null;
}

pub fn newValue(self: *lower.Lowerer, fs: *lower.FuncState, span: ast.Span, type_: cfg.Type, state: cfg.ValueState) lower.LowerError!*cfg.Value {
    const v = try self.arena.create(cfg.Value);
    v.* = .{
        .id = @intCast(fs.values.items.len),
        .span = span,
        .type_ = type_,
        .ownership = ownership(self, fs, type_),
        .state = state,
        .origin = null,
        .def = null,
    };
    // The per-function value table is SSA definition order: params
    // first (%0..%k-1), then every defined value. Appending here is
    // what gives each value a unique id — the id *is* the running
    // length, so a value that is never appended would collide with
    // every other definition (ir.md §4.1).
    try fs.values.append(self.arena, v);
    return v;
}

/// True when a block with `name` already exists in the function.
pub fn blockNameUsed(fs: *lower.FuncState, name: []const u8) bool {
    for (fs.blocks.items) |b| {
        if (std.mem.eql(u8, b.name, name)) return true;
    }
    return false;
}

pub fn fmtBlockName(self: *lower.Lowerer, prefix: []const u8, i: usize) lower.LowerError![]const u8 {
    return std.fmt.allocPrint(self.arena, "{s}_{d}", .{ prefix, i });
}

pub fn newPhi(self: *lower.Lowerer, fs: *lower.FuncState, span: ast.Span, type_: cfg.Type) lower.LowerError!?*cfg.Value {
    const v = try emit(self, fs, span, .{ .phi = .{ .incoming = &.{} } }, type_);
    const instr = v.?.def.?;
    const list = try self.arena.create(std.ArrayListUnmanaged(cfg.PhiIn));
    list.* = .empty;
    try fs.phi_lists.put(self.arena, instr, list);
    return v;
}

// -----------------------------------------------------------------
// On-the-fly optimization (braun13cc.pdf §3.1; frontend.md §4.3)
// -----------------------------------------------------------------

/// The arithmetic ops of ir.md §5.2 over numbers.
const Arith = enum { add, sub, mul, div, rem };

/// The comparison ops of ir.md §5.2.
const Cmp = enum { eq, ne, lt, le, gt, ge };

/// Fold `op` when it is a pure constant expression; null otherwise.
/// Trap-preserving (Runtime §7.2): an expression the runtime would trap
/// on — integer overflow, division/remainder by zero, `i32` negation of
/// `minInt`, `INT_MIN / -1`, or an out-of-range `float32 as int32` — is
/// left unfolded. `result_type` is the op's result type (`.neg` and
/// `.cast` need it). Exposed for the construction-time optimization
/// tests (frontend_tests.zig).
pub fn tryFoldOp(op: cfg.Op, result_type: cfg.Type) ?cfg.ConstValue {
    return switch (op) {
        .neg => |x| foldNeg(x, result_type),
        .not_ => |x| foldNot(x),
        .add => |b| foldArith(b, .add),
        .sub => |b| foldArith(b, .sub),
        .mul => |b| foldArith(b, .mul),
        .div => |b| foldArith(b, .div),
        .rem => |b| foldArith(b, .rem),
        .eq => |b| foldCmp(b, .eq),
        .ne => |b| foldCmp(b, .ne),
        .lt => |b| foldCmp(b, .lt),
        .le => |b| foldCmp(b, .le),
        .gt => |b| foldCmp(b, .gt),
        .ge => |b| foldCmp(b, .ge),
        .num_cast => |x| foldNumCast(x, result_type),
        else => return null,
    };
}

/// The `ConstValue` carried by a `const`-defined value, if any.
fn constOf(x: *cfg.Value) ?cfg.ConstValue {
    const def = x.def orelse return null;
    return switch (def.op) {
        .const_ => |c| c,
        else => null,
    };
}

fn intConst(c: cfg.ConstValue, comptime T: type) ?T {
    const U = std.meta.Int(.unsigned, @typeInfo(T).int.bits);
    return switch (c) {
        .int => |i| @bitCast(@as(U, @truncate(@as(u64, @bitCast(i))))),
        else => null,
    };
}

fn floatConst(c: cfg.ConstValue) ?f32 {
    return switch (c) {
        .float => |f| f,
        else => null,
    };
}

fn boolConst(c: cfg.ConstValue) ?bool {
    return switch (c) {
        .bool => |b| b,
        else => null,
    };
}

fn strConst(c: cfg.ConstValue) ?[]const u8 {
    return switch (c) {
        .string => |s| s,
        else => null,
    };
}

/// The primitive kind of a type, null for non-primitives.
fn primKind(t: cfg.Type) ?ast.PrimitiveKind {
    return switch (t) {
        .primitive => |k| k,
        else => null,
    };
}

/// Fold a binary arithmetic op. Integer results must not trap
/// (Runtime §7.2): overflow and division by zero are left unfolded.
fn foldArith(bin: cfg.Bin, op: Arith) ?cfg.ConstValue {
    const a = constOf(bin.a) orelse return null;
    const b = constOf(bin.b) orelse return null;
    const kind = primKind(bin.a.type_) orelse return null;
    return switch (kind) {
        .int32 => intArith(i32, a, b, op),
        .uint32 => intArith(u32, a, b, op),
        .float32 => floatArith(a, b, op),
        else => null,
    };
}

fn intArith(comptime T: type, a: cfg.ConstValue, b: cfg.ConstValue, op: Arith) ?cfg.ConstValue {
    const x = intConst(a, T) orelse return null;
    const y = intConst(b, T) orelse return null;
    switch (op) {
        .add, .sub, .mul => {
            const res, const overflow = switch (op) {
                .add => @addWithOverflow(x, y),
                .sub => @subWithOverflow(x, y),
                else => @mulWithOverflow(x, y),
            };
            if (overflow != 0) return null;
            return .{ .int = @as(i64, res) };
        },
        .div, .rem => {
            if (y == 0) return null;
            if (comptime (T == i32)) {
                if (x == std.math.minInt(i32) and y == -1) return null;
            }
            return switch (op) {
                .div => .{ .int = @as(i64, @divTrunc(x, y)) },
                else => .{ .int = @as(i64, @rem(x, y)) },
            };
        },
    }
}

/// Float arithmetic is IEEE binary32 (Runtime §7.2): it never traps, so
/// division by zero folds to ±inf and NaN propagates like the runtime.
fn floatArith(a: cfg.ConstValue, b: cfg.ConstValue, op: Arith) ?cfg.ConstValue {
    const x = floatConst(a) orelse return null;
    const y = floatConst(b) orelse return null;
    return switch (op) {
        .add => .{ .float = x + y },
        .sub => .{ .float = x - y },
        .mul => .{ .float = x * y },
        .div => .{ .float = x / y },
        .rem => null, // no float remainder op (Core §16.3)
    };
}

/// Fold a binary comparison. `==`/`!=` cover byte, int, float, bool, and
/// str; the ordering ops cover ints and floats only (Core §16.3).
fn foldCmp(bin: cfg.Bin, op: Cmp) ?cfg.ConstValue {
    const a = constOf(bin.a) orelse return null;
    const b = constOf(bin.b) orelse return null;
    const kind = primKind(bin.a.type_) orelse return null;
    const r = switch (kind) {
        .int32 => cmpInt(i32, a, b, op) orelse return null,
        .uint32 => cmpInt(u32, a, b, op) orelse return null,
        .byte => cmpByte(a, b, op) orelse return null,
        .float32 => cmpFloat(a, b, op) orelse return null,
        .bool => cmpBool(a, b, op) orelse return null,
        .str => cmpStr(a, b, op) orelse return null,
        else => return null,
    };
    return .{ .bool = r };
}

fn cmpInt(comptime T: type, a: cfg.ConstValue, b: cfg.ConstValue, op: Cmp) ?bool {
    const x = intConst(a, T) orelse return null;
    const y = intConst(b, T) orelse return null;
    return switch (op) {
        .eq => x == y,
        .ne => x != y,
        .lt => x < y,
        .le => x <= y,
        .gt => x > y,
        .ge => x >= y,
    };
}

fn cmpByte(a: cfg.ConstValue, b: cfg.ConstValue, op: Cmp) ?bool {
    if (op != .eq and op != .ne) return null;
    const x = intConst(a, u8) orelse return null;
    const y = intConst(b, u8) orelse return null;
    return if (op == .eq) x == y else x != y;
}

/// Zig float comparison matches the runtime's IEEE semantics: NaN is not
/// equal to anything (including itself) and `+0.0 == -0.0`.
fn cmpFloat(a: cfg.ConstValue, b: cfg.ConstValue, op: Cmp) ?bool {
    const x = floatConst(a) orelse return null;
    const y = floatConst(b) orelse return null;
    return switch (op) {
        .eq => x == y,
        .ne => x != y,
        .lt => x < y,
        .le => x <= y,
        .gt => x > y,
        .ge => x >= y,
    };
}

fn cmpBool(a: cfg.ConstValue, b: cfg.ConstValue, op: Cmp) ?bool {
    if (op != .eq and op != .ne) return null;
    const x = boolConst(a) orelse return null;
    const y = boolConst(b) orelse return null;
    return if (op == .eq) x == y else x != y;
}

fn cmpStr(a: cfg.ConstValue, b: cfg.ConstValue, op: Cmp) ?bool {
    if (op != .eq and op != .ne) return null;
    const x = strConst(a) orelse return null;
    const y = strConst(b) orelse return null;
    return if (op == .eq) std.mem.eql(u8, x, y) else !std.mem.eql(u8, x, y);
}

/// Fold unary negation. `neg` of `minInt(i32)` traps (Runtime §7.2), and
/// `uint32` negation's trap behavior is not defined by the specs, so both
/// stay unfolded; float negation never traps.
fn foldNeg(x: *cfg.Value, result_type: cfg.Type) ?cfg.ConstValue {
    const c = constOf(x) orelse return null;
    const kind = primKind(result_type) orelse return null;
    switch (c) {
        .int => |i| {
            if (kind == .int32) {
                const v: i32 = @truncate(i);
                if (v == std.math.minInt(i32)) return null;
                return .{ .int = -@as(i64, v) };
            }
            return null;
        },
        .float => |f| {
            if (kind != .float32) return null;
            return .{ .float = -f };
        },
        else => return null,
    }
}

fn foldNot(x: *cfg.Value) ?cfg.ConstValue {
    const c = constOf(x) orelse return null;
    const b = boolConst(c) orelse return null;
    return .{ .bool = !b };
}

/// Fold the Core §16.3 numeric conversions: `int32 as float32` and
/// `float32 as int32` (truncating toward zero with a trap when the float
/// is NaN, infinite, or out of range).
fn foldNumCast(x: *cfg.Value, target: cfg.Type) ?cfg.ConstValue {
    const c = constOf(x) orelse return null;
    const src = primKind(x.type_) orelse return null;
    const dst = primKind(target) orelse return null;
    if (src == .int32 and dst == .float32) {
        const v = intConst(c, i32) orelse return null;
        return .{ .float = @floatFromInt(v) };
    }
    if (src == .float32 and dst == .int32) {
        const f = floatConst(c) orelse return null;
        const r = floatToInt32(f) orelse return null;
        return .{ .int = r };
    }
    return null;
}

/// `f32` → `int32` (truncating toward zero), null when the runtime would
/// trap: NaN, ±infinity, or a value outside the int32 range.
fn floatToInt32(f: f32) ?i64 {
    if (std.math.isNan(f) or std.math.isInf(f)) return null;
    const lo: f32 = @floatFromInt(std.math.minInt(i32));
    if (f < lo or f >= 2147483648.0) return null;
    return @as(i64, @intFromFloat(f));
}

/// The result of arithmetic simplification: reuse an operand, fold to a
/// constant, or nothing.
const Simplify = union(enum) { none, reuse: *cfg.Value, const_: cfg.ConstValue };

/// Integer identity simplifications (braun13cc.pdf §3.1's arithmetic
/// simplification, e.g. `x − x → 0`). Integer-only — float identities
/// are unsound (`x−x ≠ 0` for NaN, `0·x ≠ 0` for ±inf/NaN, `0+x ≠ x` for
/// −0.0). Every rule is exact and trap-free for int32/uint32.
fn simplifyOp(op: cfg.Op, rt: cfg.Type) ?Simplify {
    const kind = switch (rt) {
        .primitive => |k| k,
        else => return null,
    };
    if (kind != .int32 and kind != .uint32) return null;
    return switch (op) {
        .add => |b| blk: {
            if (isZeroInt(b.b)) break :blk .{ .reuse = b.a };
            if (isZeroInt(b.a)) break :blk .{ .reuse = b.b };
            break :blk null;
        },
        .sub => |b| blk: {
            if (isZeroInt(b.b)) break :blk .{ .reuse = b.a };
            if (b.a == b.b) break :blk .{ .const_ = .{ .int = 0 } };
            break :blk null;
        },
        .mul => |b| blk: {
            if (isZeroInt(b.a) or isZeroInt(b.b)) break :blk .{ .const_ = .{ .int = 0 } };
            if (isOneInt(b.b)) break :blk .{ .reuse = b.a };
            if (isOneInt(b.a)) break :blk .{ .reuse = b.b };
            break :blk null;
        },
        .div => |b| blk: {
            if (isOneInt(b.b)) break :blk .{ .reuse = b.a };
            break :blk null;
        },
        .rem => |b| blk: {
            if (isOneInt(b.b)) break :blk .{ .const_ = .{ .int = 0 } };
            break :blk null;
        },
        else => null,
    };
}

fn isZeroInt(v: *cfg.Value) bool {
    const def = v.def orelse return false;
    return switch (def.op) {
        .const_ => |c| switch (c) {
            .int => |i| i == 0,
            else => false,
        },
        else => false,
    };
}

fn isOneInt(v: *cfg.Value) bool {
    const def = v.def orelse return false;
    return switch (def.op) {
        .const_ => |c| switch (c) {
            .int => |i| i == 1,
            else => false,
        },
        else => false,
    };
}

/// The canonical value of an identical pure computation earlier in the
/// current block, or null. The caller has already checked the result is
/// Copy; same op + operands ⇒ same result type, so one ownership
/// check suffices. Consts are never shared (matching the old CSE pass).
fn findCse(fs: *FuncState, b: *cfg.BasicBlock, op: cfg.Op) ?*cfg.Value {
    for (fs.block_instrs.items[b.id].items) |prior| {
        if (prior.results.len == 0) continue;
        if (!isCandidate(prior)) continue;
        if (cfg.identical(prior.op, op)) return prior.results[0];
    }
    return null;
}

/// True when `instr` is a pure, deterministic computation worth sharing
/// (the CSE candidate set, unchanged from the old pass). Calls, syscalls,
/// module storage, ownership transfers, `construct`, `phi`, `drop`, and
/// `copy` are never shared. In-block reuse is safe even for ops that may
/// trap — the reuse site executes exactly when the original would.
fn isCandidate(instr: *const cfg.Instr) bool {
    if (instr.results.len == 0) return false;
    return cseOk(std.meta.activeTag(instr.op));
}

/// The CSE candidate tags. A comptime check ties this set to the op
/// schema: every candidate must be side-effect-free, so a drift here
/// (reusing a call or drop) is a compile error, not a runtime surprise.
fn cseOk(tag: cfg.OpTag) bool {
    return switch (tag) {
        .neg,
        .not_,
        .num_cast,
        .tail,
        .read_tag,
        .read_payload,
        .add,
        .sub,
        .mul,
        .div,
        .rem,
        .concat,
        .eq,
        .ne,
        .lt,
        .le,
        .gt,
        .ge,
        .type_is,
        .read_field,
        .read_tuple,
        .read_index,
        => true,
        else => false,
    };
}

comptime {
    for (std.meta.tags(cfg.OpTag)) |tag| {
        if (cseOk(tag)) {
            const info = cfg.opInfo(tag);
            // A CSE candidate must be side-effect-free and non-consuming:
            // a consuming op (move, unpack_*, split_list, any_pack_move,
            // ...) changes ownership state and can never be shared. This
            // is the schema-driven exclusion — the schema's `consumes`
            // row automatically keeps every consuming op out of the
            // candidate set.
            std.debug.assert(!info.effects);
            std.debug.assert(info.consumes == .none);
        }
    }
}
