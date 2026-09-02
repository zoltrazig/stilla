//! Pass: CFG emission and function-state support (air.md §4, §6.1–§6.4).
//! In: Lowerer + per-function FuncState (blocks under construction, value
//! table, symbol table, scope stack, ownership bookkeeping).
//! Out: instructions, values, blocks, phi builders, scope-end drops, and the
//! block/value naming primitives every lowering pass builds on.
//!
//! `emit` — the AIR node constructor — also performs the **on-the-fly
//! optimizations** of braun13cc.pdf §3.1 at each construction site:
//! constant folding and arithmetic simplification (a pure op over
//! constants or integer identities folds to the constant / operand),
//! common subexpression elimination (an identical pure computation
//! earlier in the same block is reused), and copy propagation (a `copy`
//! of a Copy value is the value itself). The frontend therefore
//! needs no separate passes for these (optimizer.md, On-the-fly optimizations); partial
//! redundancy elimination, dead-block elimination, drop elision, jump
//! threading, and phi simplification still run as the Pass 8 sequence
//! over the finished program.

const std = @import("std");
const ast = @import("stilla").ast;
const cfg = @import("stilla").cfg;
const moduleinfo = @import("stilla").moduleinfo;
const lower = @import("stilla").lower;

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
        // passes (optimizer.md, On-the-fly optimizations). Order: fold, then copy elision,
        // then arithmetic simplification, then CSE.
        if (tryFoldOp(op2, rt)) |c| {
            // Constant folding: a pure op over constants becomes the
            // constant (trap-preserving — division by zero and `int32_min /
            // -1` stay unfolded, see `tryFoldOp`).
            op2 = .{ .const_ = c };
        } else if (op2 == .copy) {
            // Copy propagation: a `copy` of a Copy value is the
            // value itself (air.md §5.4). Unique copies are illegal and
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
            if (findCse(fs, b, op2, rt)) |canonical| {
                // CSE: reuse an identical pure computation earlier in
                // the same block — its result dominates every later use.
                return canonical;
            }
        }
    }
    var result: ?*cfg.Value = null;
    if (result_type) |rt| {
        const v = try newValue(self, fs, span, rt, createdState(op2, rt));
        if (v.state == .borrowed) v.origin = cfg.originOf(op2);
        result = v;
        // Scope-end destruction tracks owned unique values only: a
        // borrowed view of a unique value (read_field of an unique base,
        // borrow_variant) aliases the owner and must not
        // be dropped through.
        if (v.state == .owned and v.ownership == .unique) try fs.created.append(self.arena, v);
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

/// Emit an atomic destructure op (air.md §5.3): one instruction consumes
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

/// Emit a non-consuming multi-result variant projection (air.md §5.3):
/// this is `read_payload` generalized to a variant's whole payload set,
/// symmetric with `unpack_variant`. The base is not consumed; each result
/// is an owned *copy* when its payload type is Copy and a *borrowed view*
/// (rooted at the base) when unique — the same rule as `read_field` of a
/// unique base. The op must carry its tag so the parser/backend need not
/// recover which variant's payloads these are from the switch context.
pub fn emitBorrowVariant(self: *lower.Lowerer, fs: *lower.FuncState, span: ast.Span, base: *cfg.Value, tag: u32, result_types: []const cfg.Type) lower.LowerError![]*cfg.Value {
    const b = fs.cur orelse return &.{};
    const op: cfg.Op = .{ .borrow_variant = .{ .base = base, .tag = tag } };
    const results = try self.arena.alloc(*cfg.Value, result_types.len);
    for (result_types, 0..) |rt, i| {
        const state = readState(rt); // Copy -> owned copy, unique -> borrowed
        const v = try newValue(self, fs, span, rt, state);
        if (v.state == .borrowed) v.origin = cfg.originOf(op);
        results[i] = v;
        // Only owned unique values are destroyed at scope end; the
        // borrowed views of unique payloads alias the base.
        if (v.state == .owned and v.ownership == .unique) try fs.created.append(self.arena, v);
    }
    const instr = try self.arena.create(cfg.Instr);
    instr.* = .{ .span = span, .results = results, .op = op };
    try fs.block_instrs.items[b.id].append(self.arena, instr);
    for (results) |v| v.def = instr;
    return results;
}
/// The SSA-state of an op result (air.md §6.1–§6.5). Parameters are SSA
/// roots (air.md §5.1): their state is set when they are seeded, never by
/// an op.
pub fn createdState(op: cfg.Op, result_type: cfg.Type) cfg.ValueState {
    return switch (cfg.opInfo(std.meta.activeTag(op)).created) {
        .owned => .owned,
        .borrowed => .borrowed,
        .none => .owned, // effects produce no value; unreachable here
        .operand => switch (op) {
            .read_field, .read_tuple, .read_index, .read_payload, .borrow_variant => readState(result_type),
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
/// `T → any` coercion of a phi input on its predecessor edge (air.md
/// §4.4), where the branch block is already terminated, and the
/// `cleanup_disarm` of a token whose owner was consumed on that edge.
/// The instruction is appended after the block's existing instructions
/// (immediately before its terminator), which is the correct evaluation
/// point. No on-the-fly folding/CSE applies (these ops are not foldable
/// or shareable).
pub fn emitInto(self: *lower.Lowerer, fs: *lower.FuncState, b: *cfg.BasicBlock, span: ast.Span, op: cfg.Op, result_type: ?cfg.Type) lower.LowerError!?*cfg.Value {
    var result: ?*cfg.Value = null;
    if (result_type) |rt| {
        const v = try newValue(self, fs, span, rt, createdState(op, rt));
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

/// Disarm `v`'s cleanup state after an ownership transfer on the current
/// path. v1 (Instruction Set §4): cleanup tokens are gone — there is nothing to
/// disarm. Conditional destruction resolves at the construct's join
/// (`joinMaybeFlags`), which destroys every partially-consumed candidate
/// on its non-consuming branch edges; per-path disarm bookkeeping no
/// longer exists. Kept as a no-op so every transfer site keeps compiling.
pub fn cleanupDisable(self: *lower.Lowerer, fs: *lower.FuncState, span: ast.Span, v: *cfg.Value) lower.LowerError!void {
    _ = self;
    _ = fs;
    _ = span;
    _ = v;
}

/// `cleanupDisable` into a specific block (a branch edge or the join).
/// A no-op for the same reason.
pub fn cleanupDisableInto(self: *lower.Lowerer, fs: *lower.FuncState, b: *cfg.BasicBlock, span: ast.Span, v: *cfg.Value) lower.LowerError!void {
    _ = self;
    _ = fs;
    _ = b;
    _ = span;
    _ = v;
}

/// Drop a value (a `drop` effect); the value is dead afterwards.
/// Dropping a Copy value does nothing (Core §10.1). v1 has no cleanup
/// tokens (Instruction Set §4): a maybe-unique candidate is destroyed by the
/// join-time edge drops of `joinMaybeFlags`, so by the time any later
/// scope-end drop runs, the candidate is either definitely owned (this
/// drop fires) or already consumed (skipped).
pub fn emitDrop(self: *lower.Lowerer, fs: *lower.FuncState, span: ast.Span, v: *cfg.Value) lower.LowerError!void {
    if (!isUnique(self, fs, v.type_)) return;
    // Borrowed values are views (borrow params, `borrow` ops,
    // projections of an unique base) and are never drop candidates
    // (Core §9.2 destruction view; air.md §6.4).
    if (v.state == .borrowed) return;
    if (isConsumed(fs, v)) return;
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
    try fs.local_values.put(self.arena, value, {});
    if (owns_unique) try fs.value_locals.put(self.arena, value, local);
}

/// Resolve a name to its innermost live binding by walking the scope
/// stack outward (a shadowed outer binding is found again once the
/// shadowing scope pops). A flat symbol map is wrong here: `bindLocal`
/// would permanently clobber the enclosing binding (a match-arm pattern
/// or nested-block `let` shadowing an outer local broke every later
/// lookup — `drop t` resolved to the arm's dead binding and the compiler
/// emitted an undominated use).
pub fn lookupLocal(fs: *lower.FuncState, name: []const u8) ?*lower.Local {
    var i = fs.scopes.items.len;
    while (i > 0) {
        i -= 1;
        const locals = fs.scopes.items[i].locals.items;
        var j = locals.len;
        while (j > 0) {
            j -= 1;
            if (std.mem.eql(u8, locals[j].name, name)) return locals[j];
        }
    }
    return null;
}

/// Scope end: drop every live unique-owned local in reverse creation
/// order, except the value flowing out of the scope (air.md §6.4).
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
// Conditional-release bookkeeping (Core §10.10, air.md §6.4)
// -----------------------------------------------------------------

/// The tracked bindings of a conditional construct: the live unique
/// owners that might be consumed on some but not all paths through it.
/// Each candidate is given a cleanup token at the construct's entry; a
/// consuming path disarms it (`cleanup_disarm`), and the scope-end
/// destruction is a `cleanup_drop` of the token — destroying the payload
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
    /// The value flowing out of this branch to the join phi, if any —
    /// an edge that hands a candidate to the join phi transfers it (the
    /// edge copy is a move), which counts as consumption on that edge.
    out_val: ?*cfg.Value = null,
};

/// Snapshot the unique bindings visible at a conditional construct's
/// entry (Core §10.10): every live, owned, unique value bound to a local
/// at the current point, in value-id order. Each candidate that does not
/// already have a token gets one now — a `cleanup_arm` in the current
/// block, which dominates every branch and the join, so the token is
/// armed on every path until a consuming path disarms it. Call after the
/// condition/scrutinee has been lowered — a binding consumed there is
/// already dead and excluded. Returns an empty track when no binding can
/// be released on one branch but not another.
pub fn beginCond(self: *lower.Lowerer, fs: *lower.FuncState, span: ast.Span) lower.LowerError!CondTrack {
    _ = span;
    var cands = std.ArrayList(*cfg.Value).empty;
    for (fs.values.items) |v| {
        if (v.ownership == .unique and v.state == .owned and !isConsumed(fs, v) and fs.local_values.contains(v)) {
            try cands.append(self.arena, v);
        }
    }
    // v1 (Instruction Set §4): no cleanup tokens are created. The candidates
    // are only tracked so the join knows whose consumption was
    // conditional; partial consumption is resolved by destroying the
    // candidate on its non-consuming branch edges (`joinMaybeFlags`).
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
/// `cleanup_drop` destroys the payload only on the paths that kept it.
/// The maybe-unique value itself has no uses after the join (air.md §6.4).
pub fn joinMaybeFlags(
    self: *lower.Lowerer,
    fs: *lower.FuncState,
    track: CondTrack,
    span: ast.Span,
    branches: []const CondBranch,
) lower.LowerError!void {
    if (track.candidates.len == 0) return;
    for (track.candidates, 0..) |v, i| {
        var real: usize = 0;
        var all_released = true;
        var some_released = false;
        for (branches) |b| {
            if (b.pred == null) continue;
            real += 1;
            if (!b.released[i]) all_released = false else some_released = true;
        }
        if (real == 0) continue; // every branch trapped; nothing to merge
        if (!all_released and some_released) {
            // Consumed on some but not all completing branches (Instruction Set
            // §2.4): destroy it unconditionally at the end of every
            // branch that neither consumed nor transferred it — before
            // the merge — so the owner state agrees (dead) on every
            // path past the join. Reverse candidate order keeps the
            // destruction order consistent with scope-end teardown
            // (Runtime §6.4). The raw `.drop_` bypasses `emitDrop`'s
            // consumed check — the whole point is to fire exactly on
            // the paths that did NOT consume.
            for (branches) |b| {
                const pred = b.pred orelse continue;
                if (b.released[i]) continue;
                // An edge that hands the value to the join phi transfers
                // it (the edge copy is a move) — a consuming edge.
                if (b.out_val == v) continue;
                _ = try emitInto(self, fs, pred, span, .{ .drop_ = v }, null);
            }
            markConsumed(self, fs, v);
            if (fs.value_locals.get(v)) |l| l.consumed = true;
            continue;
        }
        if (all_released) {
            // Released on every path: definitely consumed (scope-end
            // destruction skips it).
            markConsumed(self, fs, v);
            if (fs.value_locals.get(v)) |l| l.consumed = true;
        }
        // Released on no path: still definitely owned; the ordinary
        // scope-end drop handles it later.
    }
}

// -----------------------------------------------------------------
// Blocks and values
// -----------------------------------------------------------------

pub fn newBlock(self: *lower.Lowerer, fs: *lower.FuncState, name: []const u8) lower.LowerError!*cfg.BasicBlock {
    // Block labels must be unique within a function: the printed AIR
    // text (air.md §9) is re-parsed by the standalone cfg parser, which
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
    // every other definition (air.md §4.1).
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
    const list = try self.arena.create(std.ArrayList(cfg.PhiIn));
    list.* = .empty;
    try fs.phi_lists.put(self.arena, instr, list);
    return v;
}

// -----------------------------------------------------------------
// On-the-fly optimization (braun13cc.pdf §3.1; optimizer.md, On-the-fly optimizations)
// -----------------------------------------------------------------

/// The arithmetic ops of air.md §5.2 over numbers.
const Arith = enum { add, sub, mul, div, rem };

/// The shift ops of air.md §5.2 over integers.
const Shift = enum { shl, shr };

/// The bitwise ops of air.md §5.2 over integers.
const Bit = enum { bitand, bitor, bitxor };

/// The comparison ops of air.md §5.2.
const Cmp = enum { eq, ne, lt, le, gt, ge };

/// Fold `op` when it is a pure constant expression; null otherwise.
/// Trap-preserving (Runtime §7.2): an expression the runtime would trap
/// on — division/remainder by zero, or `INT_MIN / -1` — is
/// left unfolded. Integer arithmetic wraps modulo 2³² (never traps), so
/// overflow folds to the wrapped value. Casts are total (never trap) and
/// always fold when constant. `result_type` is the op's result type
/// (`.neg` and `.cast` need it). Exposed for the construction-time
/// optimization tests (frontend_optimizer_tests.zig).
pub fn tryFoldOp(op: cfg.Op, result_type: cfg.Type) ?cfg.ConstValue {
    return switch (op) {
        .neg => |x| foldNeg(x, result_type),
        .abs => |x| foldAbs(x),
        .min => |b| foldMinMax(b, .min),
        .max => |b| foldMinMax(b, .max),
        .clz => |x| foldClz(x),
        .popcount => |x| foldPopcount(x),
        .not_ => |x| foldNot(x),
        .add => |b| foldArith(b, .add),
        .sub => |b| foldArith(b, .sub),
        .mul => |b| foldArith(b, .mul),
        .div => |b| foldArith(b, .div),
        .rem => |b| foldArith(b, .rem),
        .shl => |b| foldShift(b, .shl),
        .shr => |b| foldShift(b, .shr),
        .bitand => |b| foldBit(b, .bitand),
        .bitor => |b| foldBit(b, .bitor),
        .bitxor => |b| foldBit(b, .bitxor),
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

fn floatConst(c: cfg.ConstValue) ?f64 {
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

/// Fold a binary arithmetic op. Trap-preserving (Runtime §7.2):
/// division/remainder by zero and the `int32_min / -1` signed-division
/// overflow are left unfolded so the runtime op traps; `int32_min % -1`
/// (0, WebAssembly semantics — never traps) stays unfolded too,
/// conservatively. Integer arithmetic wraps modulo 2³² (WebAssembly
/// semantics, never traps), so overflow folds to the wrapped value; float
/// arithmetic is IEEE and always folds.
fn foldArith(bin: cfg.Bin, op: Arith) ?cfg.ConstValue {
    const a = constOf(bin.a) orelse return null;
    const b = constOf(bin.b) orelse return null;
    const kind = primKind(bin.a.type_) orelse return null;
    return switch (kind) {
        .int32 => intArith(i32, a, b, op),
        .uint32 => intArith(u32, a, b, op),
        .float32, .float64 => floatArith(a, b, op),
        else => null,
    };
}

fn intArith(comptime T: type, a: cfg.ConstValue, b: cfg.ConstValue, op: Arith) ?cfg.ConstValue {
    const x = intConst(a, T) orelse return null;
    const y = intConst(b, T) orelse return null;
    switch (op) {
        .add, .sub, .mul => {
            // Integer arithmetic wraps modulo 2³² (WebAssembly semantics,
            // Runtime §7.2): overflow folds to the truncated result.
            const res = switch (op) {
                .add => x +% y,
                .sub => x -% y,
                else => x *% y,
            };
            return .{ .int = @as(i64, res) };
        },
        .div, .rem => {
            // Division/remainder traps are preserved: a zero divisor stays
            // unfolded; the `int32_min / -1` signed-division overflow also
            // stays unfolded — mandatory for `div` (it traps), conservative
            // for `rem` (the runtime computes 0, WebAssembly semantics).
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
/// division by zero folds to ±inf and remainder by zero folds to NaN,
/// matching the runtime. Non-finite results DO fold — the AIR text form
/// represents them as inf/-inf/nan (cfg_parse accepts them), so the
/// round-trip stays faithful.
fn floatArith(a: cfg.ConstValue, b: cfg.ConstValue, op: Arith) ?cfg.ConstValue {
    const x = floatConst(a) orelse return null;
    const y = floatConst(b) orelse return null;
    return switch (op) {
        .add => .{ .float = x + y },
        .sub => .{ .float = x - y },
        .mul => .{ .float = x * y },
        .div => .{ .float = x / y },
        // Zig `@rem` on floats is the truncated remainder (C `fmod`, Rust
        // `%`), Core §16.3 / Runtime §7.2.
        .rem => .{ .float = @rem(x, y) },
    };
}

/// Fold a shift over constants. The count is taken modulo 32
/// (WebAssembly semantics, Runtime §7.2): only the low 5 bits
/// participate, so a count >= 32 folds to the masked count and a
/// negative count folds through its two's-complement pattern (`-1 & 31`
/// is 31, so `x << -1` is `x << 31`). `int32` right shift is arithmetic
/// (sign-filling), `uint32` logical (zero-filling) — Zig's `>>` is
/// already type-correct for both. Shifts never trap.
fn foldShift(bin: cfg.Bin, op: Shift) ?cfg.ConstValue {
    const a = constOf(bin.a) orelse return null;
    const b = constOf(bin.b) orelse return null;
    const kind = primKind(bin.a.type_) orelse return null;
    return switch (kind) {
        .int32 => intShift(i32, a, b, op),
        .uint32 => intShift(u32, a, b, op),
        else => null,
    };
}

fn intShift(comptime T: type, a: cfg.ConstValue, b: cfg.ConstValue, op: Shift) ?cfg.ConstValue {
    const x = intConst(a, T) orelse return null;
    const y = intConst(b, T) orelse return null;
    const s: u5 = @intCast(y & 31);
    return switch (op) {
        .shl => .{ .int = @as(i64, x << s) },
        .shr => .{ .int = @as(i64, x >> s) },
    };
}

/// Fold a bitwise op over constants. Operates on the raw 32-bit
/// patterns — `int32`/`uint32` alike, the ops are bit-identical with
/// no signedness distinction. Bitwise ops never trap (Runtime §7.2).
fn foldBit(bin: cfg.Bin, op: Bit) ?cfg.ConstValue {
    const a = constOf(bin.a) orelse return null;
    const b = constOf(bin.b) orelse return null;
    const kind = primKind(bin.a.type_) orelse return null;
    return switch (kind) {
        .int32 => intBit(i32, a, b, op),
        .uint32 => intBit(u32, a, b, op),
        else => null,
    };
}

fn intBit(comptime T: type, a: cfg.ConstValue, b: cfg.ConstValue, op: Bit) ?cfg.ConstValue {
    const x = intConst(a, T) orelse return null;
    const y = intConst(b, T) orelse return null;
    return switch (op) {
        .bitand => .{ .int = @as(i64, x & y) },
        .bitor => .{ .int = @as(i64, x | y) },
        .bitxor => .{ .int = @as(i64, x ^ y) },
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

/// Fold unary negation. `int32` negation wraps modulo 2³² (WebAssembly
/// semantics): `-int32_min` is `int32_min` itself and never traps.
/// `uint32` negation is the two's-complement `0 - x` (never traps); float
/// negation is IEEE.
fn foldNeg(x: *cfg.Value, result_type: cfg.Type) ?cfg.ConstValue {
    const c = constOf(x) orelse return null;
    const kind = primKind(result_type) orelse return null;
    switch (c) {
        .int => |i| {
            if (kind == .int32) {
                const v: i32 = @truncate(i);
                if (v == std.math.minInt(i32)) {
                    // `-minInt` wraps to `minInt` itself (modulo 2³²).
                    return .{ .int = std.math.minInt(i32) };
                }
                return .{ .int = -@as(i64, v) };
            }
            if (kind == .uint32) {
                // @truncate requires matching signedness — bitcast to
                // unsigned first, then truncate to 32 bits.
                const v: u32 = @truncate(@as(u64, @bitCast(i)));
                return .{ .int = @as(i64, @as(u32, 0) -% v) };
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

/// Fold unary absolute value. `int32` wraps modulo 2³² (WebAssembly
/// semantics): `abs(int32_min)` is `int32_min` itself — negation of the
/// minimum wraps, never traps. `float32` is IEEE `fabs` (clears the sign
/// bit — `abs(-0.0) = +0.0`). `uint32` has no abs (the identity — no
/// opcode exists), so it stays unfolded.
fn foldAbs(x: *cfg.Value) ?cfg.ConstValue {
    const c = constOf(x) orelse return null;
    const kind = primKind(x.type_) orelse return null;
    switch (c) {
        .int => |i| {
            if (kind != .int32) return null;
            const v: i32 = @truncate(i);
            return .{ .int = if (v < 0) -%v else v };
        },
        .float => |f| {
            if (kind != .float32 and kind != .float64) return null;
            return .{ .float = @abs(f) };
        },
        else => return null,
    }
}

/// Fold a binary min/max. The int32/uint32 forms compare as 32-bit
/// patterns (signedness fixed by the opcode); the f32 form follows IEEE
/// 754 `fmin`/`fmax` — NaN propagates (either operand NaN ⇒ NaN) and
/// `fmin(-0, +0) = -0` / `fmax(-0, +0) = +0`. All total — never traps,
/// always fold when constant.
fn foldMinMax(bin: cfg.Bin, op: enum { min, max }) ?cfg.ConstValue {
    const a = constOf(bin.a) orelse return null;
    const b = constOf(bin.b) orelse return null;
    const kind = primKind(bin.a.type_) orelse return null;
    switch (kind) {
        .int32 => {
            const x = intConst(a, i32) orelse return null;
            const y = intConst(b, i32) orelse return null;
            return .{ .int = if (op == .min) @min(x, y) else @max(x, y) };
        },
        .uint32 => {
            const x = intConst(a, u32) orelse return null;
            const y = intConst(b, u32) orelse return null;
            return .{ .int = if (op == .min) @min(x, y) else @max(x, y) };
        },
        .float32 => {
            const x: f64 = floatConst(a) orelse return null;
            const y: f64 = floatConst(b) orelse return null;
            return .{ .float = if (op == .min) fminIeee(f32, @floatCast(x), @floatCast(y)) else fmaxIeee(f32, @floatCast(x), @floatCast(y)) };
        },
        .float64 => {
            const x: f64 = floatConst(a) orelse return null;
            const y: f64 = floatConst(b) orelse return null;
            return .{ .float = if (op == .min) fminIeee(f64, x, y) else fmaxIeee(f64, x, y) };
        },
        else => return null,
    }
}

/// IEEE 754 `fmin`: NaN propagates, `fmin(-0, +0) = -0`. Written by
/// hand — Zig's `@min` on floats does not fix the ±0 tie the way IEEE
/// `fmin` does (a `-0.0 < 0.0` comparison is false, so a naive `@min`
/// could return `+0.0`).
fn fminIeee(comptime T: type, a: T, b: T) T {
    if (std.math.isNan(a) or std.math.isNan(b)) return std.math.nan(T);
    if (a == 0.0 and b == 0.0) return if (std.math.signbit(a)) a else b;
    return if (a < b) a else b;
}

/// IEEE 754 `fmax`: NaN propagates, `fmax(-0, +0) = +0`.
fn fmaxIeee(comptime T: type, a: T, b: T) T {
    if (std.math.isNan(a) or std.math.isNan(b)) return std.math.nan(T);
    if (a == 0.0 and b == 0.0) return if (std.math.signbit(b)) a else b;
    return if (a > b) a else b;
}

/// Fold count-leading-zeros: `clz(0) = 32`, counting the 32-bit pattern's
/// leading zero bits (WebAssembly semantics). Total — always folds when
/// constant. The result is the operand type (a count 0..32 fits both
/// int32 and uint32).
fn foldClz(x: *cfg.Value) ?cfg.ConstValue {
    const c = constOf(x) orelse return null;
    const kind = primKind(x.type_) orelse return null;
    switch (c) {
        .int => |i| {
            const pattern: u32 = switch (kind) {
                .int32 => @bitCast(@as(i32, @truncate(i))),
                .uint32 => @truncate(@as(u64, @bitCast(i))),
                else => return null,
            };
            return .{ .int = @clz(pattern) };
        },
        else => return null,
    }
}

/// Fold population count: set bits in the 32-bit pattern (WebAssembly
/// semantics). Total — always folds when constant; the result is the
/// operand type.
fn foldPopcount(x: *cfg.Value) ?cfg.ConstValue {
    const c = constOf(x) orelse return null;
    const kind = primKind(x.type_) orelse return null;
    switch (c) {
        .int => |i| {
            const pattern: u32 = switch (kind) {
                .int32 => @bitCast(@as(i32, @truncate(i))),
                .uint32 => @truncate(@as(u64, @bitCast(i))),
                else => return null,
            };
            return .{ .int = @popCount(pattern) };
        },
        else => return null,
    }
}

/// Fold the Core §16.3 numeric conversions: `int32 as float32` and
/// `float32 as int32` (truncating toward zero; a NaN or out-of-range
/// source saturates, NaN becomes zero — casts never trap, Runtime §7.2).
fn foldNumCast(x: *cfg.Value, target: cfg.Type) ?cfg.ConstValue {
    const c = constOf(x) orelse return null;
    const src = primKind(x.type_) orelse return null;
    const dst = primKind(target) orelse return null;
    if (src == .int32 and dst == .float32) {
        const v = intConst(c, i32) orelse return null;
        return .{ .float = @floatFromInt(v) };
    }
    if (src == .float32 and dst == .int32) {
        const f: f64 = floatConst(c) orelse return null;
        return .{ .int = floatToInt32(@floatCast(f)) };
    }
    return null;
}

/// `f32` → `int32` (truncating toward zero). Total — casts never trap:
/// NaN becomes zero, and values at/above 2³¹ or below −2³¹ saturate to
/// the `int32` range (Runtime §7.2).
fn floatToInt32(f: f32) i64 {
    if (std.math.isNan(f)) return 0;
    if (f >= 2147483648.0) return std.math.maxInt(i32);
    const lo: f32 = @floatFromInt(std.math.minInt(i32));
    if (f < lo) return std.math.minInt(i32);
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
        // Shift by zero is the identity (the count is masked mod 32, so
        // `<< 0` and `>> 0` shift by nothing); a count >= 32 or negative
        // count is NOT a folded identity here — the count const stays and
        // the masked result is computed at runtime.
        .shl => |b| blk: {
            if (isZeroInt(b.b)) break :blk .{ .reuse = b.a };
            break :blk null;
        },
        .shr => |b| blk: {
            if (isZeroInt(b.b)) break :blk .{ .reuse = b.a };
            break :blk null;
        },
        // Bitwise identities (commutative — either side may hold the
        // zero): `x & 0 -> 0`, `x | 0 -> x`, `x ^ 0 -> x`. The all-ones
        // identities (`x & -1 -> x`, `x | -1 -> -1`) are skipped: the
        // all-ones pattern differs between int32 and uint32 constants
        // and is not worth a fragile match.
        .bitand => |b| blk: {
            if (isZeroInt(b.a) or isZeroInt(b.b)) break :blk .{ .const_ = .{ .int = 0 } };
            break :blk null;
        },
        .bitor => |b| blk: {
            if (isZeroInt(b.a)) break :blk .{ .reuse = b.b };
            if (isZeroInt(b.b)) break :blk .{ .reuse = b.a };
            break :blk null;
        },
        .bitxor => |b| blk: {
            if (isZeroInt(b.a)) break :blk .{ .reuse = b.b };
            if (isZeroInt(b.b)) break :blk .{ .reuse = b.a };
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
fn findCse(fs: *FuncState, b: *cfg.BasicBlock, op: cfg.Op, rt: cfg.Type) ?*cfg.Value {
    for (fs.block_instrs.items[b.id].items) |prior| {
        if (prior.results.len == 0) continue;
        if (!isCandidate(prior)) continue;
        if (cfg.identical(prior.op, op)) {
            // The key must also agree on the result type: `num_cast`
            // carries only the operand, so `x as uint32` and `x as f64`
            // of one source share a key — with the uniform conversion
            // family that is a value-changing collision (a byte
            // truncation vs a float widen), never a reuse.
            if (cfg.Type.eql(prior.results[0].type_, rt)) return prior.results[0];
        }
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
        .abs,
        .clz,
        .popcount,
        .not_,
        .num_cast,
        // The reuse is exact only when the destination type agrees too
        // (the `findCse` key adds the result type — the `cfg.Op` key
        // alone cannot distinguish `x as uint32` from `x as f64`).
        .tail,
        .read_tag,
        .read_payload,
        .add,
        .sub,
        .mul,
        .div,
        .rem,
        .min,
        .max,
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
