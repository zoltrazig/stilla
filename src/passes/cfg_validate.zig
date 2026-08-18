//! Pass: CFG IR validity validator — the ir.md §12 invariant set,
//! enforced (frontend.md Pass 6.1). In: a `cfg.IrProgram` (freshly
//! lowered, or after any optimization pass). Out: null when the program
//! satisfies the invariants, or a human-readable first-violation message.
//!
//! The validator is schema-driven: op arity, ownership effect, created
//! state, and the may-trap / side-effect classification all come from
//! `cfg.opInfo`, so the hand-written switches here and the machine
//! contract cannot drift (adding an op without a schema row is a compile
//! error). Checks, in order:
//!
//! - **Structure** — entry has no predecessors; `phi` only at block
//!   heads, one incoming per predecessor in `preds` order; `store_member`
//!   only inside `@init`; `arg` indices in range.
//! - **SSA** — each value defined exactly once and dominated: every
//!   non-phi use is dominated by its definition; every phi operand is
//!   defined in (or dominates) its named predecessor block.
//! - **Arity** — every op carries its schema-declared value-operand
//!   count (3-address, with the documented n-ary exceptions).
//! - **Typing** — the statically checkable operand/result type rules:
//!   numeric ops over same-typed numerics, `concat` over `str`, casts
//!   over the Core §16.3 pair, `any`-ops over `any`, projections over
//!   their shapes, `copy` never over an unique operand, `drop` never
//!   over a Copy value, cleanup ops over cleanup tokens.
//! - **Ownership dataflow** — an edge-sensitive forward analysis over
//!   unique values (`Available` / `Consumed` / `MaybeConsumed`, merged
//!   at joins): a consuming op (move, take, drop, move-mode argument,
//!   phi input, `ret`, `any_pack_move`, `any_unpack_move`) requires its
//!   operand *available*; a value in `MaybeConsumed` state has no uses
//!   at all (its destruction is scheduled through its cleanup token,
//!   ir.md §6.4); a `borrowed` value is never consumed; `ret` never
//!   returns a borrowed view. This is the check that keeps the
//!   optimizer's rewrites (drop elision, TCO, PRE, dead-block
//!   elimination) honest about destruction.

const std = @import("std");
const cfg = @import("../cfg.zig");
const ast = @import("../ast.zig");

/// The per-value availability state along a path (ir.md §12 Ownership):
/// alive (owned), consumed (dead on this path), or consumed on some
/// paths and alive on others after a join (maybe-unique, Core §10.10).
const AState = enum { available, consumed, maybe };

const StateMap = std.AutoHashMap(*const cfg.Value, AState);

/// Validate a whole program. Returns null when valid, otherwise the
/// first violation as a message (allocated from `allocator`).
pub fn validate(program: *const cfg.IrProgram, allocator: std.mem.Allocator) !?[]const u8 {
    for (program.funcs) |f| {
        if (try validateFunc(program, f, allocator)) |m| return m;
    }
    return null;
}

/// Validate one function.
fn validateFunc(program: *const cfg.IrProgram, f: *const cfg.IrFunc, allocator: std.mem.Allocator) !?[]const u8 {
    const n = f.blocks.len;

    // ---- Structure ----
    if (f.entry.preds.len != 0) {
        return msg(allocator, "function @{s}: entry block '{s}' has {d} predecessors", .{ f.name.text, f.entry.name, f.entry.preds.len });
    }
    for (f.blocks) |b| {
        var seen_non_phi = false;
        for (b.instrs) |instr| {
            if (instr.op == .phi and seen_non_phi) {
                return msg(allocator, "function @{s}: phi in block '{s}' appears after a non-phi instruction", .{ f.name.text, b.name });
            }
            if (instr.op != .phi) seen_non_phi = true;
        }
        for (b.instrs) |instr| {
            if (instr.op != .phi) continue;
            const phi = instr.op.phi;
            if (phi.incoming.len != b.preds.len) {
                return msg(allocator, "function @{s}: phi in block '{s}' has {d} incomings but {d} predecessors", .{ f.name.text, b.name, phi.incoming.len, b.preds.len });
            }
            for (phi.incoming, b.preds) |inc, p| {
                if (inc.pred != p) {
                    return msg(allocator, "function @{s}: phi incoming order does not match predecessors in block '{s}'", .{ f.name.text, b.name });
                }
            }
        }
    }

    // ---- Forward edge consistency ----
    // Every terminator edge must be reflected in the target's `preds`
    // (ir.md §4.3, the one-incoming-per-pred contract): a branch to a
    // block that does not list this block as a predecessor is a dangling
    // edge — execution would enter the target along a path its phis do
    // not expect. Rewrites that drop chain edges (tail-call elimination,
    // §7.2) must keep the rest of the graph coherent; this catches the
    // stale terminator left behind if one does not. `ret` and `trap`
    // have no edges. Dead trap stubs (blocks without predecessors) may
    // carry a `{self}` pred and are skipped by the reachability
    // analysis, not by this check: their `trap` terminator has no edge.
    for (f.blocks) |b| {
        const targets: []const *const cfg.BasicBlock = switch (b.terminator) {
            .j => |t| &.{t},
            .br => |bc| &.{ bc.then_, bc.else_ },
            .@"switch" => |s| blk: {
                var ts = std.ArrayList(*const cfg.BasicBlock).empty;
                for (s.arms) |arm| try ts.append(allocator, arm.block);
                break :blk try ts.toOwnedSlice(allocator);
            },
            .ret, .tailcall, .trap => continue,
        };
        for (targets) |t| {
            var listed = false;
            for (t.preds) |p| {
                if (p == b) {
                    listed = true;
                    break;
                }
            }
            if (!listed) {
                return msg(allocator, "function @{s}: terminator of block '{s}' targets '{s}', which does not list it as a predecessor", .{ f.name.text, b.name, t.name });
            }
        }
    }

    // ---- Dominators (iterative) ----
    // dom[i] is the set of blocks dominating block i. Entry dominates
    // itself; blocks without predecessors (dead trap stubs) keep {self}.
    // Blocks are indexed by their *position* in `f.blocks` — block ids
    // are creation indices and are not dense after dead-block
    // elimination removes blocks from the middle.
    var index_of = std.AutoHashMap(*const cfg.BasicBlock, usize).init(allocator);
    for (f.blocks, 0..) |b, i| try index_of.put(b, i);
    const blkIndex = struct {
        fn of(m: *const std.AutoHashMap(*const cfg.BasicBlock, usize), b: *const cfg.BasicBlock) ?usize {
            return m.get(b);
        }
    }.of;
    const dom = try allocator.alloc([]bool, n);
    defer {
        for (dom) |row| allocator.free(row);
        allocator.free(dom);
    }
    for (f.blocks, 0..) |_, i| {
        dom[i] = try allocator.alloc(bool, n);
        @memset(dom[i], true);
        for (0..n) |j| {
            if (i != j and f.blocks[j].preds.len != 0) dom[i][j] = false;
        }
    }
    var changed = true;
    while (changed) {
        changed = false;
        for (f.blocks, 0..) |b, i| {
            if (b.preds.len == 0) continue;
            var acc = try allocator.alloc(bool, n);
            defer allocator.free(acc);
            @memcpy(acc, dom[blkIndex(&index_of, b.preds[0]) orelse unreachable]);
            for (b.preds[1..]) |p| {
                const pi = blkIndex(&index_of, p) orelse unreachable;
                for (0..n) |j| acc[j] = acc[j] and dom[pi][j];
            }
            acc[i] = true;
            var diff = false;
            for (0..n) |j| {
                if (acc[j] != dom[i][j]) {
                    diff = true;
                    break;
                }
            }
            if (diff) {
                @memcpy(dom[i], acc);
                changed = true;
            }
        }
    }

    // ---- Ownership dataflow: block-entry states, fixed point ----
    // Maps are allocator-owned (the program's arena); the pass frees
    // nothing individually.
    const entries = try allocator.alloc(StateMap, n);
    for (entries) |*e| e.* = StateMap.init(allocator);
    // The last computed exit state per block, used for the edge-sensitive
    // phi-input check (an input arrives on one edge, where its state is
    // authoritative — not the merged join state).
    const exits = try allocator.alloc(StateMap, n);
    for (exits) |*e| e.* = StateMap.init(allocator);
    // Seed: entry-block parameter values (unique, non-borrow mode).
    for (f.params, 0..) |p, i| {
        const v = f.values[i];
        if (v.state == .owned and v.ownership != .copy and p.mode != .borrow) {
            try entries[0].put(v, .available);
        }
    }

    var worklist = std.ArrayList(*const cfg.BasicBlock).empty;
    defer worklist.deinit(allocator);
    try worklist.append(allocator, f.entry);
    const in_queue = try allocator.alloc(bool, n);
    defer allocator.free(in_queue);
    @memset(in_queue, false);
    in_queue[0] = true;
    const reachable = try allocator.alloc(bool, n);
    defer allocator.free(reachable);
    @memset(reachable, false);
    reachable[0] = true;
    // Reachability: blocks the fixpoint ever enqueues. Unreachable
    // blocks are transient (TCO chain leftovers the dead-block pass
    // removes, and trap-terminated dead stubs, ir.md §14.7): their *semantic*
    // checks are skipped — a dead block may violate dominance or
    // ownership harmlessly because it never executes. Structural checks
    // above still apply to every block.

    while (worklist.items.len > 0) {
        const b = worklist.pop().?;
        const bi = blkIndex(&index_of, b) orelse unreachable;
        in_queue[bi] = false;
        const exit = try exitState(b, entries[bi], allocator);
        exits[bi] = exit;
        const succs = try successors(b, allocator);
        for (succs) |s| {
            const si = blkIndex(&index_of, s) orelse {
                return msg(allocator, "function @{s}: terminator of block '{s}' targets a block outside the function", .{ f.name.text, b.name });
            };
            // Every first-seen successor is enqueued once, so a block
            // with no unique state still propagates reachability; the
            // fixpoint re-enqueues only on state change.
            const first = !reachable[si];
            reachable[si] = true;
            const st_changed = try mergeState(&entries[si], exit, allocator);
            if ((first or st_changed) and !in_queue[si]) {
                in_queue[si] = true;
                try worklist.append(allocator, s);
            }
        }
    }

    // ---- Per-block checks, with the fixed-point entry states ----
    for (f.blocks, 0..) |b, i| {
        if (!reachable[i]) continue; // unreachable: semantic checks skipped
        var st = entries[i];
        // Phi group first (block head). Each incoming is checked against
        // its arriving edge's exit state (ir.md §6.3: the phi transfers
        // ownership of the value that actually arrived).
        for (b.instrs) |instr| {
            if (instr.op != .phi) break;
            const phi = instr.op.phi;
            for (phi.incoming) |inc| {
                if (!cfg.Type.eql(instr.results[0].type_, inc.value.type_)) {
                    return msg(allocator, "function @{s}: phi in '{s}' joins value %{d} of type {any} into {any}", .{ f.name.text, b.name, inc.value.id, inc.value.type_, instr.results[0].type_ });
                }
                const ep = blkIndex(&index_of, inc.pred) orelse unreachable;
                if (try checkEdgeAvailable(f, b, instr, inc.value, exits[ep], "phi input", allocator)) |m| return m;
                // A phi operand must be defined in (or dominate) its
                // named predecessor block (ir.md §13 SSA) — unless that
                // predecessor is unreachable (dead TCO-chain junk the
                // dead-block pass removes; dominance is vacuous there).
                if (reachable[ep]) {
                    if (try checkUse(f, inc.pred, instr, inc.value, dom, allocator)) |m| return m;
                }
                if (inc.value.ownership != .copy) try st.put(inc.value, .consumed);
            }
            if (instr.results[0].ownership != .copy) try st.put(instr.results[0], .available);
        }
        for (b.instrs) |instr| {
            if (instr.op == .phi) continue;
            if (try checkInstr(program, f, b, instr, dom, &st, allocator)) |m| return m;
        }
        if (try checkTerminator(program, f, b, dom, &st, allocator)) |m| return m;
    }

    return null;
}

/// The successors of `b` in edge order (allocator-owned; a `switch` has
/// one successor per arm).
fn successors(b: *const cfg.BasicBlock, allocator: std.mem.Allocator) ![]const *const cfg.BasicBlock {
    var out = std.ArrayList(*const cfg.BasicBlock).empty;
    switch (b.terminator) {
        .ret, .tailcall, .trap => {},
        .j => |t| try out.append(allocator, t),
        .br => |bc| {
            try out.append(allocator, bc.then_);
            try out.append(allocator, bc.else_);
        },
        .@"switch" => |s| for (s.arms) |arm| try out.append(allocator, arm.block),
    }
    return try out.toOwnedSlice(allocator);
}

fn msg(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !?[]const u8 {
    return @as(?[]const u8, try std.fmt.allocPrint(allocator, fmt, args));
}

/// The state map after walking `b` from its entry state: unique results
/// become available, consumed operands become consumed. The transfer is
/// deterministic, so the exit map is a fresh copy of the entry map plus
/// the instruction effects.
fn exitState(b: *const cfg.BasicBlock, entry: StateMap, allocator: std.mem.Allocator) !StateMap {
    var st = StateMap.init(allocator);
    var it = entry.iterator();
    while (it.next()) |e| try st.put(e.key_ptr.*, e.value_ptr.*);
    for (b.instrs) |instr| {
        try transfer(instr, &st);
        for (instr.results) |r| {
            if (r.ownership != .copy) try st.put(r, .available);
        }
    }
    return st;
}

/// The dataflow transfer of one instruction's consumption, without
/// checks (used to compute the fixed point).
fn transfer(instr: *const cfg.Instr, st: *StateMap) !void {
    const info = cfg.opInfo(std.meta.activeTag(instr.op));
    switch (info.consumes) {
        .none => {},
        .op0 => try consume(st, operand0(instr.op)),
        .op1 => try consume(st, operand1(instr.op)),
        .both => {
            try consume(st, operand0(instr.op));
            try consume(st, operand1(instr.op));
        },
        .all => {
            // phi: every incoming transfers ownership to the result.
            if (instr.op == .phi) {
                for (instr.op.phi.incoming) |inc| try consume(st, inc.value);
            }
        },
    }
}

fn consume(st: *StateMap, v: ?*const cfg.Value) !void {
    if (v) |val| {
        if (val.ownership != .copy) try st.put(val, .consumed);
    }
}

fn operand0(op: cfg.Op) ?*const cfg.Value {
    return switch (op) {
        .neg, .not_, .num_cast, .any_pack_copy, .any_pack_move, .any_unpack_copy, .any_unpack_move, .cleanup_arm, .cleanup_disarm, .cleanup_drop, .copy, .borrow, .move_, .tail, .unpack_struct, .unpack_tuple, .split_list, .read_tag, .read_payload, .drop_ => |v| v,
        .unpack_variant => |uv| uv.base,
        .borrow_variant => |bv| bv.base,
        .type_is => |x| x.value,
        .load_member => |x| x.module,
        .read_field, .read_tuple => |x| x.base,
        .store_member => |x| x.value,
        else => null,
    };
}

fn operand1(op: cfg.Op) ?*const cfg.Value {
    return switch (op) {
        .read_index => |x| x.index,
        else => null,
    };
}

/// Merge `in` into `out` (join lattice: available ⊔ consumed = maybe;
/// maybe absorbs). Returns true when `out` changed.
fn mergeState(out: *StateMap, in: StateMap, allocator: std.mem.Allocator) !bool {
    _ = allocator;
    var changed = false;
    var it = in.iterator();
    while (it.next()) |e| {
        const v = e.key_ptr.*;
        const s = e.value_ptr.*;
        if (out.get(v)) |cur| {
            const merged = if (cur == s) cur else AState.maybe;
            if (merged != cur) {
                try out.put(v, merged);
                changed = true;
            }
        } else {
            try out.put(v, s);
            changed = true;
        }
    }
    return changed;
}

/// Check that a value is available on a specific arriving edge (the
/// pred block's exit state) — used for phi inputs. Borrowed and
/// Copy values are untracked.
fn checkEdgeAvailable(
    f: *const cfg.IrFunc,
    b: *const cfg.BasicBlock,
    instr: *const cfg.Instr,
    v: *const cfg.Value,
    edge: StateMap,
    what: []const u8,
    allocator: std.mem.Allocator,
) !?[]const u8 {
    _ = instr;
    if (v.state == .borrowed or v.ownership == .copy) return null;
    if (edge.get(v)) |s| {
        switch (s) {
            .available => {},
            .consumed => return msg(allocator, "function @{s}: {s} %{d} is consumed on its arriving edge into block '{s}'", .{ f.name.text, what, v.id, b.name }),
            .maybe => return msg(allocator, "function @{s}: {s} %{d} is maybe-unique on its arriving edge into block '{s}'", .{ f.name.text, what, v.id, b.name }),
        }
    }
    return null;
}

/// The availability check for a schema-consumed operand: it must be
/// available on this path (not already consumed, not maybe).
fn checkConsumedOperand(
    f: *const cfg.IrFunc,
    b: *const cfg.BasicBlock,
    instr: *const cfg.Instr,
    v: ?*const cfg.Value,
    st: StateMap,
    allocator: std.mem.Allocator,
) !?[]const u8 {
    const val = v orelse return null;
    // Borrowed views can never be consumed (the per-op checks below
    // report the specific violation); skip the availability lattice for
    // them and for Copy values.
    if (val.state == .borrowed or val.ownership == .copy) return null;
    if (st.get(val)) |s| {
        switch (s) {
            .available => {},
            .consumed => return msg(allocator, "function @{s}: '{s}' consumes already-consumed value %{d} in block '{s}'", .{ f.name.text, cfg.opInfo(std.meta.activeTag(instr.op)).text, val.id, b.name }),
            .maybe => return msg(allocator, "function @{s}: '{s}' consumes maybe-unique value %{d} in block '{s}' (unusable after a conditional construct, ir.md §6.4)", .{ f.name.text, cfg.opInfo(std.meta.activeTag(instr.op)).text, val.id, b.name }),
        }
    }
    return null;
}

/// Check that a value is available at a use site (not consumed on this
/// path, not maybe). Borrowed and Copy values are untracked.
fn checkAvailable(
    f: *const cfg.IrFunc,
    b: *const cfg.BasicBlock,
    instr: *const cfg.Instr,
    v: *const cfg.Value,
    st: StateMap,
    what: []const u8,
    allocator: std.mem.Allocator,
) !?[]const u8 {
    _ = instr;
    if (v.state == .borrowed or v.ownership == .copy) return null;
    if (st.get(v)) |s| {
        switch (s) {
            .available => {},
            .consumed => return msg(allocator, "function @{s}: {s} uses already-consumed value %{d} in block '{s}'", .{ f.name.text, what, v.id, b.name }),
            .maybe => return msg(allocator, "function @{s}: {s} uses maybe-unique value %{d} in block '{s}' (unusable after a conditional construct, ir.md §6.4)", .{ f.name.text, what, v.id, b.name }),
        }
    }
    return null;
}

/// Static operand checks + dataflow transfer for one non-phi
/// instruction.
fn checkInstr(
    program: *const cfg.IrProgram,
    f: *const cfg.IrFunc,
    b: *const cfg.BasicBlock,
    instr: *const cfg.Instr,
    dom: [][]bool,
    st: *StateMap,
    allocator: std.mem.Allocator,
) !?[]const u8 {
    const info = cfg.opInfo(std.meta.activeTag(instr.op));

    // ---- Arity (schema) ----
    const count = valueOperandCount(instr.op);
    const ok_arity = switch (info.arity) {
        .zero => count == 0,
        .one => count == 1,
        .two => count == 2,
        .nary => true,
    };
    if (!ok_arity) {
        return msg(allocator, "function @{s}: '{s}' in block '{s}' has {d} value operands, expected {s}", .{ f.name.text, info.text, b.name, count, @tagName(info.arity) });
    }

    // ---- Result count (schema) ----
    // Single-result ops define exactly 0 (pure effects) or 1 value; the
    // atomic destructure ops (`.multi`) define one or more.
    if (info.multi) {
        if (instr.results.len < 1) {
            return msg(allocator, "function @{s}: '{s}' in block '{s}' defines no results (an atomic destructure defines at least one)", .{ f.name.text, info.text, b.name });
        }
    } else {
        // `call`/`syscall` may legitimately define no result (a void
        // return); every other single-result op defines exactly 0
        // (pure effects) or 1.
        const may_omit = instr.op == .call or instr.op == .syscall;
        const expect: usize = if (info.created == .none) 0 else 1;
        if (instr.results.len != expect and !(may_omit and instr.results.len == 0)) {
            return msg(allocator, "function @{s}: '{s}' in block '{s}' defines {d} results, expected {d}", .{ f.name.text, info.text, b.name, instr.results.len, expect });
        }
    }

    // ---- Availability of consumed operands (schema) ----
    // The ops whose ownership effect is fixed (move, take, drop,
    // any_pack_move, any_unpack_move, store_member) require their operand
    // available on this path; call/syscall argument modes are checked in
    // their own cases (they depend on the signature).
    switch (info.consumes) {
        .none => {},
        .op0 => if (try checkConsumedOperand(f, b, instr, operand0(instr.op), st.*, allocator)) |m| return m,
        .op1 => if (try checkConsumedOperand(f, b, instr, operand1(instr.op), st.*, allocator)) |m| return m,
        .both => {
            if (try checkConsumedOperand(f, b, instr, operand0(instr.op), st.*, allocator)) |m| return m;
            if (try checkConsumedOperand(f, b, instr, operand1(instr.op), st.*, allocator)) |m| return m;
        },
        .all => {}, // phi: checked at the block head, edge-sensitively
    }

    // ---- SSA dominance for every operand ----
    const ops = try collectOperands(instr, allocator);
    for (ops) |v| {
        if (try checkUse(f, b, instr, v, dom, allocator)) |m| return m;
        // Borrow provenance (ir.md §6.5): a borrowed view's root must be
        // Available on this path.
        if (v.state == .borrowed) {
            if (try checkBorrowRoot(f, b, v, st.*, allocator)) |m| return m;
        }
    }

    // ---- Typing + static ownership rules (per op) ----
    switch (instr.op) {
        .const_, .module_ref, .fn_ref => {},
        .neg => |v| {
            if (!isNumeric(v.type_)) return typeErr(allocator, f, b, info.text, v.type_);
        },
        .not_ => |v| {
            if (!isBool(v.type_)) return typeErr(allocator, f, b, "not", v.type_);
        },
        .num_cast => |v| {
            // The numeric cast types are the full integer/float family
            // (Core §16.3: int32 ↔ float32, int32 ↔ byte, int32 ↔ uint32,
            // byte ↔ int32, uint32 ↔ int32); distinct from the arithmetic
            // `isNumeric` set, which gates add/sub/mul/div/rem.
            if (!isNumCastType(v.type_) or !isNumCastType(instr.results[0].type_)) {
                return typeErr(allocator, f, b, "num_cast", v.type_);
            }
        },
        .type_is => |x| {
            if (!isAny(x.value.type_) or !isBool(instr.results[0].type_)) return typeErr(allocator, f, b, "type_is", x.value.type_);
        },
        .any_pack_copy, .any_pack_move => |v| {
            if (!isAny(instr.results[0].type_)) return typeErr(allocator, f, b, info.text, v.type_);
        },
        .any_unpack_copy, .any_unpack_move => |v| {
            if (!isAny(v.type_)) return typeErr(allocator, f, b, info.text, v.type_);
        },
        .add, .sub, .mul, .div, .rem => |x| {
            if (!isNumeric(x.a.type_) or !cfg.Type.eql(x.a.type_, x.b.type_) or !cfg.Type.eql(x.a.type_, instr.results[0].type_)) {
                return typeErr(allocator, f, b, info.text, x.a.type_);
            }
        },
        .concat => |x| {
            if (!isStr(x.a.type_) or !isStr(x.b.type_)) return typeErr(allocator, f, b, "concat", x.a.type_);
        },
        .eq, .ne, .lt, .le, .gt, .ge => |x| {
            if (!cfg.Type.eql(x.a.type_, x.b.type_) or !isBool(instr.results[0].type_)) return typeErr(allocator, f, b, info.text, x.a.type_);
        },
        .copy => |v| {
            if (v.ownership == .unique) return typeErr(allocator, f, b, "copy", v.type_);
        },
        .borrow => |v| {
            if (!cfg.Type.eql(v.type_, instr.results[0].type_)) return typeErr(allocator, f, b, "borrow", v.type_);
        },
        .move_ => |v| {
            if (v.state == .borrowed) {
                return msg(allocator, "function @{s}: move of borrowed value %{d} in block '{s}' (Core §10.7)", .{ f.name.text, v.id, b.name });
            }
        },
        .drop_ => |v| {
            if (v.ownership == .copy) {
                return msg(allocator, "function @{s}: drop of Copy value %{d} in block '{s}' (the frontend never emits it)", .{ f.name.text, v.id, b.name });
            }
            if (v.state == .borrowed) {
                return msg(allocator, "function @{s}: drop of borrowed value %{d} in block '{s}' (Core §10.7)", .{ f.name.text, v.id, b.name });
            }
        },
        .cleanup_arm => |v| {
            if (instr.results[0].type_ != .cleanup) return typeErr(allocator, f, b, "cleanup_arm", v.type_);
        },
        .cleanup_disarm, .cleanup_drop => |v| {
            if (v.type_ != .cleanup) {
                return msg(allocator, "function @{s}: {s} operand %{d} is not a cleanup token in block '{s}'", .{ f.name.text, info.text, v.id, b.name });
            }
        },
        .load_member => |x| {
            if (x.module.type_ != .module) return typeErr(allocator, f, b, "load_member", x.module.type_);
            // The member table (ir.md §7, §12): the member index must
            // name a member of the module the base value refers to, and
            // the member's kind must match the load (a constant member
            // reads its slot, a function member yields a function value,
            // a module-valued member yields the module value). The module
            // identity resolves through the base's `module_ref` /
            // module-valued `load_member` chain (`IrProgram.moduleOf`);
            // modules without a member table (text-form IR) skip the
            // check.
            const m = program.moduleOf(x.module) orelse return null;
            const members = m.members orelse return null;
            if (x.member >= members.len) {
                return msg(allocator, "function @{s}: load_member #{d} in block '{s}' is out of range for module '{s}' ({d} members)", .{ f.name.text, x.member, b.name, m.name, members.len });
            }
            const member = members[x.member];
            switch (member.kind) {
                .const_slot => |slot| {
                    // A constant member reads its storage slot — a
                    // distinct index space from member indices (ir.md
                    // §7). A null slot is a storage-less void constant.
                    if (slot) |s| {
                        if (s >= m.slots.len) {
                            return msg(allocator, "function @{s}: load_member #{d} of member '{s}' references slot #{d} out of range for module '{s}' ({d} slots)", .{ f.name.text, x.member, member.name, s, m.name, m.slots.len });
                        }
                        if (!cfg.Type.eql(m.slots[s].type_, member.type_)) {
                            return msg(allocator, "function @{s}: member '{s}' of module '{s}' has type {any} but its slot holds {any}", .{ f.name.text, member.name, m.name, member.type_, m.slots[s].type_ });
                        }
                    }
                },
                .function, .host_binding, .module_ref => {},
            }
            if (!cfg.Type.eql(member.type_, instr.results[0].type_)) {
                return msg(allocator, "function @{s}: load_member #{d} of member '{s}' ({any}) produces {any} in block '{s}'", .{ f.name.text, x.member, member.name, member.type_, instr.results[0].type_, b.name });
            }
        },
        .store_member => |x| {
            // `store_member` writes constant slot #i of the current
            // module — legal only inside @init (checked above), and the
            // slot must exist with a matching type (ir.md §7, §12).
            if (!std.mem.eql(u8, f.name.text, "init")) {
                return msg(allocator, "function @{s}: store_member outside @init (ir.md §5.6)", .{f.name.text});
            }
            if (f.module_spec) |spec| {
                if (cfg.moduleByName(program, spec)) |m| {
                    // Text-form modules have no member table; their slots
                    // derive from the store ops themselves, so the bounds
                    // check is vacuous there — skip (ir.md §10).
                    if (m.members != null) {
                        if (x.slot >= m.slots.len) {
                            return msg(allocator, "function @{s}: store_member #{d} is out of range for module '{s}' ({d} slots)", .{ f.name.text, x.slot, m.name, m.slots.len });
                        }
                        if (!cfg.Type.eql(x.value.type_, m.slots[x.slot].type_)) {
                            // The `T -> any` coercion is implicit at the
                            // constant boundary (ir.md §4.4 lists call and
                            // join boundaries only; module constants store
                            // the evaluated value into the declared slot),
                            // so an `any`-typed slot accepts any value
                            // type.
                            if (!isAny(m.slots[x.slot].type_)) {
                                return msg(allocator, "function @{s}: store_member #{d} of type {any} does not match slot type {any} of module '{s}'", .{ f.name.text, x.slot, x.value.type_, m.slots[x.slot].type_, m.name });
                            }
                        }
                    }
                }
            }
        },
        .construct => |c| {
            // A tagged construct is a union variant: the tag must name a
            // variant of the result's union and the argument count must
            // match the variant's payload arity (ir.md §12). An untagged
            // construct (struct / tuple / list literal) may not target an
            // opaque type (ir.md §12, opaque bases).
            const r = namedDecl(program, instr.results[0].type_);
            if (c.tag) |tag| {
                const rd = r orelse return typeErr(allocator, f, b, "construct", instr.results[0].type_);
                switch (rd.decl) {
                    .union_ => |u| {
                        if (tag >= u.variants.len) {
                            return msg(allocator, "function @{s}: construct #tag {d} names no variant of '{s}' in block '{s}'", .{ f.name.text, tag, u.name, b.name });
                        }
                        if (c.args.len != u.variants[tag].payloads.len) {
                            return msg(allocator, "function @{s}: construct #tag {d} passes {d} arguments to the {d}-payload variant '{s}' of '{s}' in block '{s}'", .{ f.name.text, tag, c.args.len, u.variants[tag].payloads.len, u.variants[tag].name, u.name, b.name });
                        }
                    },
                    .opaque_ => return opaqueErr(allocator, f, b, "construct"),
                    .struct_, .unknown => return typeErr(allocator, f, b, "construct", instr.results[0].type_),
                }
            } else if (r) |rd| switch (rd.decl) {
                .opaque_ => return opaqueErr(allocator, f, b, "construct"),
                else => {},
            };
        },
        .read_field => |x| {
            // Bases are structs; the index names a field of the
            // `StructDecl` and the result is typed as that field (ir.md
            // §12).
            const r = namedDecl(program, x.base.type_) orelse
                return typeErr(allocator, f, b, "read_field", x.base.type_);
            switch (r.decl) {
                .opaque_ => return opaqueErr(allocator, f, b, "read_field"),
                .struct_ => |s| {
                    if (x.index >= s.fields.len) {
                        return msg(allocator, "function @{s}: read_field #{d} names no field of '{s}' ({d} fields) in block '{s}'", .{ f.name.text, x.index, s.name, s.fields.len, b.name });
                    }
                    const ft = cfg.substParams(allocator, s.type_params, r.n.args, s.fields[x.index].type_);
                    if (!cfg.Type.eql(instr.results[0].type_, ft)) {
                        return msg(allocator, "function @{s}: read_field #{d} of '{s}' produces {any}, expected its declared field type {any} in block '{s}'", .{ f.name.text, x.index, s.name, instr.results[0].type_, ft, b.name });
                    }
                },
                .union_ => return typeErr(allocator, f, b, "read_field", x.base.type_),
                .unknown => {},
            }
        },
        .read_tuple => |x| {
            // Bases are tuples; the index names an element and the
            // result is typed as that element (ir.md §12).
            switch (x.base.type_) {
                .tuple => |elems| {
                    if (x.index >= elems.len) {
                        return msg(allocator, "function @{s}: read_tuple #{d} out of range for a {d}-element tuple in block '{s}'", .{ f.name.text, x.index, elems.len, b.name });
                    }
                    if (!cfg.Type.eql(instr.results[0].type_, elems[x.index])) {
                        return msg(allocator, "function @{s}: read_tuple #{d} produces {any}, expected {any} in block '{s}'", .{ f.name.text, x.index, instr.results[0].type_, elems[x.index], b.name });
                    }
                },
                .named => |n| switch (program.typeDecl(n.id) orelse return typeErr(allocator, f, b, "read_tuple", x.base.type_)) {
                    .opaque_ => return opaqueErr(allocator, f, b, "read_tuple"),
                    .unknown => {},
                    else => return typeErr(allocator, f, b, "read_tuple", x.base.type_),
                },
                else => return typeErr(allocator, f, b, "read_tuple", x.base.type_),
            }
        },
        .read_index => |x| {
            if (x.base.type_ != .list) return typeErr(allocator, f, b, info.text, x.base.type_);
        },
        .tail => |v| {
            if (v.type_ != .list or instr.results[0].type_ != .list) return typeErr(allocator, f, b, info.text, v.type_);
        },
        // Atomic destructures: the base must be owned (a consuming op of
        // a borrowed view violates Core §10.7), and for the aggregate
        // types the destructure defines exactly the parts (ir.md §12).
        .unpack_struct => |v| {
            if (v.state == .borrowed) {
                return msg(allocator, "function @{s}: {s} of borrowed value %{d} in block '{s}' (Core §10.7)", .{ f.name.text, info.text, v.id, b.name });
            }
            const r = namedDecl(program, v.type_) orelse return typeErr(allocator, f, b, "unpack_struct", v.type_);
            switch (r.decl) {
                .opaque_ => return opaqueErr(allocator, f, b, "unpack_struct"),
                .struct_ => |s| {
                    if (instr.results.len != s.fields.len) {
                        return msg(allocator, "function @{s}: unpack_struct of '{s}' defines {d} results, expected its {d} fields", .{ f.name.text, s.name, instr.results.len, s.fields.len });
                    }
                },
                .union_ => return typeErr(allocator, f, b, "unpack_struct", v.type_),
                .unknown => {},
            }
        },
        .unpack_tuple => |v| {
            if (v.state == .borrowed) {
                return msg(allocator, "function @{s}: {s} of borrowed value %{d} in block '{s}' (Core §10.7)", .{ f.name.text, info.text, v.id, b.name });
            }
            switch (v.type_) {
                .tuple => |elems| {
                    if (instr.results.len != elems.len) {
                        return msg(allocator, "function @{s}: unpack_tuple defines {d} results, expected the tuple's {d} elements", .{ f.name.text, instr.results.len, elems.len });
                    }
                },
                .named => |n| switch (program.typeDecl(n.id) orelse return typeErr(allocator, f, b, "unpack_tuple", v.type_)) {
                    .opaque_ => return opaqueErr(allocator, f, b, "unpack_tuple"),
                    .unknown => {},
                    else => return typeErr(allocator, f, b, "unpack_tuple", v.type_),
                },
                else => return typeErr(allocator, f, b, "unpack_tuple", v.type_),
            }
        },
        .split_list => |v| {
            if (v.state == .borrowed) {
                return msg(allocator, "function @{s}: {s} of borrowed value %{d} in block '{s}' (Core §10.7)", .{ f.name.text, info.text, v.id, b.name });
            }
        },
        .unpack_variant => |uv| {
            if (uv.base.state == .borrowed) {
                return msg(allocator, "function @{s}: unpack_variant of borrowed value %{d} in block '{s}' (Core §10.7)", .{ f.name.text, uv.base.id, b.name });
            }
            // The base is a union, the tag names one of its variants,
            // and the destructure defines exactly the variant's payloads
            // (ir.md §12).
            switch (unionBase(program, uv.base) orelse return typeErr(allocator, f, b, "unpack_variant", uv.base.type_)) {
                .resolved => |ru| {
                    if (uv.tag >= ru.u.variants.len) {
                        return msg(allocator, "function @{s}: unpack_variant #tag {d} names no variant of '{s}' in block '{s}'", .{ f.name.text, uv.tag, ru.u.name, b.name });
                    }
                    if (instr.results.len != ru.u.variants[uv.tag].payloads.len) {
                        return msg(allocator, "function @{s}: unpack_variant #tag {d} of '{s}' defines {d} results, expected the variant's {d} payloads", .{ f.name.text, uv.tag, ru.u.name, instr.results.len, ru.u.variants[uv.tag].payloads.len });
                    }
                },
                .unknown => {},
            }
        },
        // `borrow_variant` does not consume its base (it reads the
        // payloads of the switch-dispatched variant), so the base may be
        // owned or borrowed; the base is a union, the tag names one of
        // its variants, and the projection defines exactly the variant's
        // payloads (ir.md §12).
        .borrow_variant => |bv| {
            switch (unionBase(program, bv.base) orelse return typeErr(allocator, f, b, "borrow_variant", bv.base.type_)) {
                .resolved => |ru| {
                    if (bv.tag >= ru.u.variants.len) {
                        return msg(allocator, "function @{s}: borrow_variant #tag {d} names no variant of '{s}' in block '{s}'", .{ f.name.text, bv.tag, ru.u.name, b.name });
                    }
                    if (instr.results.len != ru.u.variants[bv.tag].payloads.len) {
                        return msg(allocator, "function @{s}: borrow_variant #tag {d} of '{s}' defines {d} results, expected the variant's {d} payloads", .{ f.name.text, bv.tag, ru.u.name, instr.results.len, ru.u.variants[bv.tag].payloads.len });
                    }
                },
                .unknown => {},
            }
        },
        .read_tag, .read_payload => |v| {
            // Bases are unions (ir.md §12); `read_tag` yields the
            // discriminant as a tag index.
            if (instr.op == .read_tag and (instr.results[0].type_ != .primitive or instr.results[0].type_.primitive != .uint32)) {
                return typeErr(allocator, f, b, "read_tag", instr.results[0].type_);
            }
            switch (unionBase(program, v) orelse return typeErr(allocator, f, b, info.text, v.type_)) {
                .resolved => {},
                .unknown => {},
            }
        },
        .call => |c| {
            // Move-mode arguments consume; borrow/plain pass views. For a
            // direct call the callee's signature gives the modes; a value
            // callee's function type carries them. A void-typed parameter
            // carries no observable value and produces no operand in the
            // call (phase3-cfg-lowering.md, Lowering rules), so the mode mapping skips it — the
            // lowering emits one operand per non-void parameter.
            const params = calleeParams(c);
            var pi: usize = 0;
            for (c.args) |a| {
                while (pi < params.len and (params[pi].type_ == .primitive and params[pi].type_.primitive == .void)) pi += 1;
                const mode: ast.ParamMode = if (pi < params.len) params[pi].mode else .plain;
                if (mode == .move) {
                    if (try checkAvailable(f, b, instr, a, st.*, "move-mode argument", allocator)) |m| return m;
                    if (a.ownership != .copy) try st.put(a, .consumed);
                } else {
                    if (a.ownership != .copy and a.state != .borrowed) {
                        if (st.get(a)) |s| {
                            if (s != .available) {
                                return msg(allocator, "function @{s}: argument %{d} is {s} in block '{s}'", .{ f.name.text, a.id, @tagName(s), b.name });
                            }
                        }
                    }
                }
                pi += 1;
            }
        },
        .syscall => |s| {
            // The syscall's specialized signature (ir.md §8.2, §12):
            // argument count, types, and modes against the parameters —
            // the same checks `call` performs against its callee
            // signature. The lowering emits one operand per non-void
            // parameter; a text-form syscall carries no signature (null)
            // and skips the check.
            if (s.sig) |sig| {
                var pi: usize = 0;
                for (s.args) |a| {
                    while (pi < sig.params.len and isVoid(sig.params[pi].type_)) pi += 1;
                    if (pi >= sig.params.len) {
                        return msg(allocator, "function @{s}: syscall passes more arguments than its signature has parameters in block '{s}'", .{ f.name.text, b.name });
                    }
                    const p = sig.params[pi];
                    if (!cfg.Type.eql(a.type_, p.type_)) {
                        return msg(allocator, "function @{s}: syscall argument %{d} of type {any} does not match parameter type {any} in block '{s}'", .{ f.name.text, a.id, a.type_, p.type_, b.name });
                    }
                    if (p.mode == .move) {
                        // A move-mode parameter consumes its argument: it
                        // must be owned and available — a borrowed value
                        // can never be moved (Core §10.7, ir.md §6.2).
                        if (a.state == .borrowed) {
                            return msg(allocator, "function @{s}: move-mode syscall argument %{d} is borrowed in block '{s}' (Core §10.7)", .{ f.name.text, a.id, b.name });
                        }
                        if (try checkAvailable(f, b, instr, a, st.*, "move-mode syscall argument", allocator)) |m| return m;
                        if (a.ownership != .copy) try st.put(a, .consumed);
                    } else {
                        // plain/borrow pass a view; the argument itself is
                        // not consumed (a borrowed argument's root is
                        // checked by the general borrow-root walk above).
                        if (a.ownership != .copy and a.state != .borrowed) {
                            if (st.get(a)) |a_st| {
                                if (a_st != .available) {
                                    return msg(allocator, "function @{s}: syscall argument %{d} is {s} in block '{s}'", .{ f.name.text, a.id, @tagName(a_st), b.name });
                                }
                            }
                        }
                    }
                    pi += 1;
                }
                while (pi < sig.params.len and isVoid(sig.params[pi].type_)) pi += 1;
                if (pi != sig.params.len) {
                    return msg(allocator, "function @{s}: syscall passes fewer arguments than its signature has parameters in block '{s}'", .{ f.name.text, b.name });
                }
                // The result type matches the signature's return (a
                // void/never return produces no result).
                if (instr.results.len == 1 and !cfg.Type.eql(instr.results[0].type_, sig.ret.*)) {
                    return msg(allocator, "function @{s}: syscall result %{d} of type {any} does not match return type {any}", .{ f.name.text, instr.results[0].id, instr.results[0].type_, sig.ret.* });
                }
            }
            //
            // `builtin#peek` of a non-Copy payload must produce a
            // borrowed view (ir.md §6.5): an owned result would be
            // destroyed through the box at scope end AND by the box's
            // own destruction — a double free.
            if (s.target == .builtin and s.target.builtin == .peek and instr.results.len == 1) {
                const r = instr.results[0];
                if (r.ownership != .copy and r.state == .owned) {
                    return msg(allocator, "function @{s}: syscall builtin#peek result %{d} of non-Copy type must be a borrowed view (ir.md §6.5)", .{ f.name.text, r.id });
                }
            }
        },
        .phi => unreachable, // handled at the block head
    }

    // ---- Dataflow transfer for this instruction ----
    try transfer(instr, st);
    for (instr.results) |r| {
        if (r.ownership != .copy) try st.put(r, .available);
    }
    return null;
}

/// The terminator checks: `ret` consumes its unique value (never a
/// borrowed view; type-matched to the return type, modulo `never`),
/// every terminator operand is dominated by its definition, and a
/// `switch` dispatches on a `read_tag` result with arms covering
/// exactly the union's variants (ir.md §12).
fn checkTerminator(program: *const cfg.IrProgram, f: *const cfg.IrFunc, b: *const cfg.BasicBlock, dom: [][]bool, st: *StateMap, allocator: std.mem.Allocator) !?[]const u8 {
    switch (b.terminator) {
        .ret => |v| {
            const val = v orelse return null;
            if (try checkUse(f, b, null, val, dom, allocator)) |m| return m;
            if (val.state == .borrowed) {
                return msg(allocator, "function @{s}: ret of borrowed value %{d} in block '{s}' (Core §10.7)", .{ f.name.text, val.id, b.name });
            }
            if (!cfg.Type.eql(val.type_, f.ret)) {
                const is_never = val.type_ == .primitive and val.type_.primitive == .never;
                if (!is_never) {
                    return msg(allocator, "function @{s}: ret value %{d} of type {any} does not match return type {any}", .{ f.name.text, val.id, val.type_, f.ret });
                }
            }
            if (val.ownership != .copy) {
                if (st.get(val)) |s| {
                    if (s != .available) {
                        return msg(allocator, "function @{s}: ret of non-available value %{d} in block '{s}'", .{ f.name.text, val.id, b.name });
                    }
                }
            }
        },
        .j, .trap => {},
        .tailcall => |tc| {
            // A `tailcall` is a direct self-call: the target must be the
            // enclosing function, the argument list must match the
            // parameter list in arity, type, and mode, each argument must
            // be dominated, a move-mode argument must be available and is
            // consumed (ownership transfers into the reused frame), and a
            // borrow-mode argument must not borrow a root the frame reuse
            // would destroy.
            if (tc.func) |target| {
                if (target != f) {
                    return msg(allocator, "function @{s}: tailcall targets '@{s}', not the enclosing function (Core §…) — a tailcall must be a self-call", .{ f.name.text, target.name.text });
                }
            }
            if (tc.args.len != f.params.len) {
                return msg(allocator, "function @{s}: tailcall passes {d} arguments to a {d}-parameter function", .{ f.name.text, tc.args.len, f.params.len });
            }
            for (tc.args, f.params) |a, p| {
                if (try checkUse(f, b, null, a, dom, allocator)) |m| return m;
                if (!cfg.Type.eql(a.type_, p.type_)) {
                    return msg(allocator, "function @{s}: tailcall argument %{d} of type {any} does not match parameter type {any}", .{ f.name.text, a.id, a.type_, p.type_ });
                }
                if (p.mode == .move) {
                    if (a.ownership != .copy) {
                        if (st.get(a)) |s| {
                            if (s != .available) {
                                return msg(allocator, "function @{s}: tailcall move-mode argument %{d} is not available in block '{s}'", .{ f.name.text, a.id, b.name });
                            }
                        }
                        try st.put(a, .consumed);
                    }
                } else {
                    if (a.ownership != .copy and a.state != .borrowed) {
                        if (st.get(a)) |s| {
                            if (s == .consumed) {
                                return msg(allocator, "function @{s}: tailcall borrow-mode argument %{d} is consumed before the tailcall in block '{s}'", .{ f.name.text, a.id, b.name });
                            }
                        }
                    }
                    if (a.state == .borrowed) {
                        if (try checkBorrowRoot(f, b, a, st.*, allocator)) |m| return m;
                    }
                }
            }
        },
        .br => |bc| {
            if (try checkUse(f, b, null, bc.cond, dom, allocator)) |m| return m;
            if (bc.cond.state == .borrowed) {
                if (try checkBorrowRoot(f, b, bc.cond, st.*, allocator)) |m| return m;
            }
        },
        .@"switch" => |sw| {
            if (try checkUse(f, b, null, sw.disc, dom, allocator)) |m| return m;
            if (sw.disc.state == .borrowed) {
                if (try checkBorrowRoot(f, b, sw.disc, st.*, allocator)) |m| return m;
            }
            // Arm tags are exactly the union's variants — exhaustive,
            // with the implicit trap default unreachable and no bogus or
            // repeated tags (ir.md §12). The union resolves through the
            // disc's defining `read_tag`; a switch whose disc does not
            // resolve (text-form IR) skips the check.
            const ub = resolveSwitchUnion(program, sw.disc) orelse return null;
            const ru = switch (ub) {
                .resolved => |ru| ru,
                .unknown => return null,
            };
            if (sw.arms.len != ru.u.variants.len) {
                return msg(allocator, "function @{s}: switch in block '{s}' has {d} arms for the {d} variants of '{s}' (ir.md §12)", .{ f.name.text, b.name, sw.arms.len, ru.u.variants.len, ru.u.name });
            }
            const seen = try allocator.alloc(bool, ru.u.variants.len);
            defer allocator.free(seen);
            @memset(seen, false);
            for (sw.arms) |arm| {
                if (arm.tag >= ru.u.variants.len) {
                    return msg(allocator, "function @{s}: switch arm #tag {d} names no variant of '{s}' in block '{s}'", .{ f.name.text, arm.tag, ru.u.name, b.name });
                }
                if (seen[arm.tag]) {
                    return msg(allocator, "function @{s}: switch arm #tag {d} repeats in block '{s}'", .{ f.name.text, arm.tag, b.name });
                }
                seen[arm.tag] = true;
            }
        },
    }
    return null;
}

/// The value-operand count of an op (the 3-address arity, ir.md §4.2).
fn valueOperandCount(op: cfg.Op) usize {
    return switch (op) {
        .const_, .module_ref, .fn_ref => 0,
        .neg, .not_, .num_cast, .any_pack_copy, .any_pack_move, .any_unpack_copy, .any_unpack_move, .cleanup_arm, .cleanup_disarm, .cleanup_drop, .copy, .borrow, .move_, .tail, .unpack_struct, .unpack_tuple, .unpack_variant, .borrow_variant, .split_list, .read_tag, .read_payload, .drop_ => 1,
        .type_is => 1,
        .load_member => 1,
        .store_member => 1,
        .read_field, .read_tuple => 1,
        .read_index => 2,
        .add, .sub, .mul, .div, .rem, .concat, .eq, .ne, .lt, .le, .gt, .ge => 2,
        .construct => |c| c.args.len,
        .call => |c| c.args.len,
        .syscall => |s| s.args.len,
        .phi => |p| p.incoming.len,
    };
}

/// All value operands of an instruction, for the dominance check.
fn collectOperands(instr: *const cfg.Instr, allocator: std.mem.Allocator) ![]*const cfg.Value {
    var out = std.ArrayList(*const cfg.Value).empty;
    errdefer out.deinit(allocator);
    switch (instr.op) {
        .neg, .not_, .num_cast, .any_pack_copy, .any_pack_move, .any_unpack_copy, .any_unpack_move, .cleanup_arm, .cleanup_disarm, .cleanup_drop, .copy, .borrow, .move_, .tail, .unpack_struct, .unpack_tuple, .split_list, .read_tag, .read_payload, .drop_ => |v| try out.append(allocator, v),
        .unpack_variant => |uv| try out.append(allocator, uv.base),
        .borrow_variant => |bv| try out.append(allocator, bv.base),
        .type_is => |x| try out.append(allocator, x.value),
        .load_member => |x| try out.append(allocator, x.module),
        .store_member => |x| try out.append(allocator, x.value),
        .read_field, .read_tuple => |x| try out.append(allocator, x.base),
        .read_index => |x| {
            try out.append(allocator, x.base);
            try out.append(allocator, x.index);
        },
        .add, .sub, .mul, .div, .rem, .concat, .eq, .ne, .lt, .le, .gt, .ge => |x| {
            try out.append(allocator, x.a);
            try out.append(allocator, x.b);
        },
        .construct => |c| for (c.args) |a| try out.append(allocator, a),
        .call => |c| {
            if (c.callee == .value) try out.append(allocator, c.callee.value);
            for (c.args) |a| try out.append(allocator, a);
        },
        .syscall => |s| for (s.args) |a| try out.append(allocator, a),
        .phi => {},
        .const_, .module_ref, .fn_ref => {},
    }
    return out.toOwnedSlice(allocator);
}

/// The callee's parameters, for argument-mode checks (empty when the
/// callee is unresolvable).
fn calleeParams(c: cfg.Call) []const cfg.Param {
    return switch (c.callee) {
        .direct => |d| if (d.func) |fn_| fn_.params else &.{},
        .value => |v| switch (v.type_) {
            .function => |ft| ft.params,
            else => &.{},
        },
    };
}

/// The ultimate borrow root (ir.md §6.5): follow a borrowed value's
/// origin chain to the root whose availability gates its uses — an owned
/// value, the `call` lifetime, or a `peek` owner. A Copy root makes
/// the availability check vacuous (Copy values are never consumed).
const UltimateRoot = union(enum) {
    value: *const cfg.Value,
    call,
    peek,
};

fn ultimateRoot(v: *const cfg.Value) UltimateRoot {
    if (v.ownership == .copy) return .{ .value = v }; // vacuous root
    const origin = v.origin orelse return .{ .value = v }; // owned / no origin
    switch (origin) {
        .call => return .call,
        .peek => return .peek,
        .root => |base| {
            // Resolve transitively through the view chain: a base that is
            // itself borrowed resolves to its own root; an owned base stops.
            if (base.state == .owned) return .{ .value = base };
            return ultimateRoot(base);
        },
    }
}

/// ir.md §6.5: every use of a borrowed value requires its ultimate root
/// to be Available at the use point. A `call` root needs no check inside
/// the callee (the caller's argument is valid for the whole call, Core
/// §10.7); a `peek` root is bound to the producing syscall's argument;
/// a Copy root makes the check vacuous. An owned unique root must not be
/// consumed on the reaching path.
fn checkBorrowRoot(
    f: *const cfg.IrFunc,
    b: *const cfg.BasicBlock,
    v: *const cfg.Value,
    st: StateMap,
    allocator: std.mem.Allocator,
) !?[]const u8 {
    switch (ultimateRoot(v)) {
        .call => return null,
        .peek => return null,
        .value => |rv| {
            if (rv.ownership == .copy) return null;
            if (st.get(rv)) |s| {
                switch (s) {
                    .available => {},
                    .consumed => return msg(allocator, "function @{s}: use of borrowed value %{d} after its root %{d} was consumed in block '{s}' (ir.md §6.5)", .{ f.name.text, v.id, rv.id, b.name }),
                    .maybe => return msg(allocator, "function @{s}: use of borrowed value %{d} whose root %{d} is maybe-unique in block '{s}' (ir.md §6.5)", .{ f.name.text, v.id, rv.id, b.name }),
                }
            }
            return null;
        },
    }
}

/// The dominance check for one use: the definition's block must dominate
/// the use's block (a use in the same block comes after the definition).
/// `instr` is the using instruction; null for a terminator operand (a use
/// after every instruction in the block).
fn checkUse(
    f: *const cfg.IrFunc,
    b: *const cfg.BasicBlock,
    instr: ?*const cfg.Instr,
    v: *const cfg.Value,
    dom: [][]bool,
    allocator: std.mem.Allocator,
) !?[]const u8 {
    const def = v.def orelse return null; // parameter
    const db = defBlock(f, def) orelse return null;
    if (db == b) {
        if (instr) |use| {
            var seen = false;
            for (b.instrs) |i| {
                if (i == def) {
                    seen = true;
                } else if (i == use) {
                    if (!seen) {
                        return msg(allocator, "function @{s}: use of %{d} before its definition in block '{s}'", .{ f.name.text, v.id, b.name });
                    }
                    break;
                }
            }
        }
        return null;
    }
    const use_idx = blockIndex(f, b);
    const def_idx = blockIndex(f, db);
    if (!dom[use_idx][def_idx]) {
        return msg(allocator, "function @{s}: use of %{d} in block '{s}' is not dominated by its definition", .{ f.name.text, v.id, b.name });
    }
    return null;
}

/// A block's position in its function (a scan; CFGs are small).
fn blockIndex(f: *const cfg.IrFunc, b: *const cfg.BasicBlock) usize {
    for (f.blocks, 0..) |x, i| {
        if (x == b) return i;
    }
    unreachable;
}

/// The block containing an instruction (a scan; CFGs are small).
fn defBlock(f: *const cfg.IrFunc, instr: *const cfg.Instr) ?*const cfg.BasicBlock {
    for (f.blocks) |b| {
        for (b.instrs) |i| {
            if (i == instr) return b;
        }
    }
    return null;
}

fn isNumeric(t: cfg.Type) bool {
    return t == .primitive and (t.primitive == .int32 or t.primitive == .uint32 or t.primitive == .float32);
}

/// The type set a `num_cast` may move between (Core §16.3): the integer
/// family plus float32. Arithmetic (`isNumeric`) stays as-is; enabling
/// a cast does not enable `byte + byte` or `uint32` negation.
fn isNumCastType(t: cfg.Type) bool {
    return t == .primitive and (t.primitive == .int32 or t.primitive == .uint32 or t.primitive == .byte or t.primitive == .float32);
}

fn isBool(t: cfg.Type) bool {
    return t == .primitive and t.primitive == .bool;
}

fn isStr(t: cfg.Type) bool {
    return t == .primitive and t.primitive == .str;
}

fn isAny(t: cfg.Type) bool {
    return t == .primitive and t.primitive == .any;
}

fn isVoid(t: cfg.Type) bool {
    return t == .primitive and t.primitive == .void;
}

fn typeErr(allocator: std.mem.Allocator, f: *const cfg.IrFunc, b: *const cfg.BasicBlock, what: []const u8, t: cfg.Type) !?[]const u8 {
    _ = t;
    return msg(allocator, "function @{s}: '{s}' operand/result type mismatch in block '{s}'", .{ f.name.text, what, b.name });
}

// ---------------------------------------------------------------------------
// ir.md §12 type checks — struct / union / tuple / opaque layout
// ---------------------------------------------------------------------------

/// The declaration behind a named type (ir.md §9.1): null for non-named
/// types and out-of-range ids. An `.unknown` row (text-form IR — the
/// text form carries no type declarations, ir.md §10) makes every layout
/// query null, so the §12 checks skip it rather than reject.
const NamedDecl = struct {
    n: cfg.Type.Named,
    decl: cfg.TypeDecl,
};

fn namedDecl(program: *const cfg.IrProgram, t: cfg.Type) ?NamedDecl {
    return switch (t) {
        .named => |n| blk: {
            const decl = program.typeDecl(n.id) orelse return null;
            break :blk .{ .n = n, .decl = decl };
        },
        else => null,
    };
}

const UnionResolved = struct {
    nd: NamedDecl,
    u: cfg.UnionDecl,
};

/// The union a union-base op's base resolves to (ir.md §12 "read_tag /
/// read_payload / borrow_variant bases are unions"):
///  - `resolved` — the base is a concrete union;
///  - `unknown` — the base is a named type without a layout (text-form
///    IR); the check skips;
///  - null — the base is not a union (a violation).
const UnionBase = union(enum) {
    resolved: UnionResolved,
    unknown,
};

fn unionBase(program: *const cfg.IrProgram, base: *const cfg.Value) ?UnionBase {
    const nd = namedDecl(program, base.type_) orelse return null;
    return switch (nd.decl) {
        .union_ => |u| .{ .resolved = .{ .nd = nd, .u = u } },
        .unknown => .unknown,
        else => null,
    };
}

/// The union a `switch` dispatches on (ir.md §12): the disc is a
/// `read_tag` result; its base resolves the union. Null when the disc is
/// not a `read_tag` of a concrete union (text-form IR) — the
/// exhaustive-arm check skips.
fn resolveSwitchUnion(program: *const cfg.IrProgram, disc: *const cfg.Value) ?UnionBase {
    const def = disc.def orelse return null;
    const base = switch (def.op) {
        .read_tag => |v| v,
        else => return null,
    };
    return unionBase(program, base);
}

/// ir.md §12 opaque bases: the excluded ops may not target an
/// `opaque(OpaqueDecl)` type (Core §11.8).
fn opaqueErr(allocator: std.mem.Allocator, f: *const cfg.IrFunc, b: *const cfg.BasicBlock, what: []const u8) !?[]const u8 {
    return msg(allocator, "function @{s}: '{s}' may not target an opaque type in block '{s}' (Core §11.8)", .{ f.name.text, what, b.name });
}

// ---------------------------------------------------------------------------
// White-box tests: the validator accepts valid programs and rejects the
// ir.md §13 violations a lowering or optimizer bug would produce.
// ---------------------------------------------------------------------------

const cfg_parse = @import("cfg_parse.zig");

fn parseAndValidate(text: []const u8) !?[]const u8 {
    var t = try cfg_parse.parseText(text);
    defer t.arena.deinit();
    // The validator's maps are arena-owned (never freed individually),
    // so it runs against an arena; the message is copied out into the
    // caller's allocator so it outlives the helper.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const m = try validate(&t.program, arena.allocator());
    if (m) |mmsg| return @as(?[]const u8, try std.testing.allocator.dupe(u8, mmsg));
    return null;
}

test "validator accepts a lowered-style program with cleanup tokens" {
    const msg_ = try parseAndValidate(
        \\module "app" {
        \\    func @main() -> void {
        \\    entry:
        \\        %0: int32 = const 1
        \\        %1: File = construct %0
        \\        %2: cleanup = cleanup_arm %1
        \\        %3: bool = const true
        \\        br %3 ? then : join
        \\    then:
        \\        %4: File = move %1
        \\        cleanup_disarm %2
        \\        call @consume, %4
        \\        j join
        \\    join:
        \\        cleanup_drop %2
        \\        ret
        \\    }
        \\    func @consume(move f: File) -> void {
        \\    entry:
        \\        drop %0
        \\        ret
        \\    }
        \\}
    );
    try std.testing.expect(msg_ == null);
}

test "validator rejects a double move" {
    const msg_ = try parseAndValidate(
        \\module "app" {
        \\    func @f(move a: File) -> File {
        \\    entry:
        \\        %1: File = move %0
        \\        %2: File = move %0
        \\        ret %2
        \\    }
        \\}
    );
    defer if (msg_) |m| std.testing.allocator.free(m);
    try std.testing.expect(msg_ != null);
    try std.testing.expect(std.mem.indexOf(u8, msg_.?, "already-consumed") != null);
}

test "validator rejects use after consumption" {
    const msg_ = try parseAndValidate(
        \\module "app" {
        \\    func @f(move a: File) -> void {
        \\    entry:
        \\        %1: File = move %0
        \\        drop %0
        \\        ret
        \\    }
        \\}
    );
    defer if (msg_) |m| std.testing.allocator.free(m);
    try std.testing.expect(msg_ != null);
    try std.testing.expect(std.mem.indexOf(u8, msg_.?, "already-consumed") != null);
}

test "validator rejects a ret of a borrowed value" {
    const msg_ = try parseAndValidate(
        \\module "app" {
        \\    func @f(borrow a: File) -> File {
        \\    entry:
        \\        ret %0
        \\    }
        \\}
    );
    defer if (msg_) |m| std.testing.allocator.free(m);
    try std.testing.expect(msg_ != null);
    try std.testing.expect(std.mem.indexOf(u8, msg_.?, "borrowed") != null);
}

test "validator rejects a non-dominated use" {
    // `%1` is defined in `b`; `c` is reached directly from the entry, so
    // `b` does not dominate `c` and the use of `%1` there is invalid SSA.
    const msg_ = try parseAndValidate(
        \\module "app" {
        \\    func @f(c: bool) -> int32 {
        \\    entry:
        \\        br %0 ? b : c
        \\    b:
        \\        %1: int32 = const 1
        \\        j join
        \\    c:
        \\        ret %1
        \\    join:
        \\        ret %1
        \\    }
        \\}
    );
    defer if (msg_) |m| std.testing.allocator.free(m);
    try std.testing.expect(msg_ != null);
    try std.testing.expect(std.mem.indexOf(u8, msg_.?, "not dominated") != null);
}

test "validator rejects a phi with mixed incoming types" {
    const msg_ = try parseAndValidate(
        \\module "app" {
        \\    func @f(c: bool) -> int32 {
        \\    entry:
        \\        %1: int32 = const 1
        \\        %2: str = const "x"
        \\        br %0 ? a : b
        \\    a:
        \\        j join
        \\    b:
        \\        j join
        \\    join:
        \\        %3: int32 = phi [%1, a], [%2, b]
        \\        ret %3
        \\    }
        \\}
    );
    defer if (msg_) |m| std.testing.allocator.free(m);
    try std.testing.expect(msg_ != null);
    try std.testing.expect(std.mem.indexOf(u8, msg_.?, "joins value") != null);
}

test "validator rejects an any_unpack of a non-any operand" {
    const msg_ = try parseAndValidate(
        \\module "app" {
        \\    func @f(x: int32) -> int32 {
        \\    entry:
        \\        %1: int32 = any_unpack_copy %0
        \\        ret %1
        \\    }
        \\}
    );
    defer if (msg_) |m| std.testing.allocator.free(m);
    try std.testing.expect(msg_ != null);
    try std.testing.expect(std.mem.indexOf(u8, msg_.?, "type mismatch") != null);
}

/// Parse text-form IR, then install concrete type declarations over the
/// interned names (the text form carries no type declarations, ir.md
/// §10 — the §12 layout checks skip unknown rows, so a test must supply
/// the layout to exercise them). Declarations are indexed by interning
/// order: the i-th named type in the text gets decls[i].
fn parseValidateWithDecls(text: []const u8, decls: []const cfg.TypeDecl) !?[]const u8 {
    var t = try cfg_parse.parseText(text);
    defer t.arena.deinit();
    for (decls, 0..) |d, i| {
        if (i >= t.program.types.len) break;
        t.program.types[i] = d;
    }
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const m = try validate(&t.program, arena.allocator());
    if (m) |mmsg| return @as(?[]const u8, try std.testing.allocator.dupe(u8, mmsg));
    return null;
}

/// `Result`: two variants, `Ok(str)` (one payload) and `Err` (none).
const result_union = cfg.TypeDecl{ .union_ = .{
    .name = "Result",
    .module = "use",
    .type_params = &.{},
    .ownership = .unique,
    .variants = @constCast(&[_]cfg.VariantDecl{
        .{ .name = "Ok", .payloads = @constCast(&[_]cfg.Type{.{ .primitive = .str }}) },
        .{
            .name = "Err",
            .payloads = @constCast(&[_]cfg.Type{}),
        },
    }),
} };

/// `Pair`: one field `a: int32`.
const pair_struct = cfg.TypeDecl{ .struct_ = .{
    .name = "Pair",
    .module = "use",
    .type_params = &.{},
    .ownership = .copy,
    .drop = null,
    .fields = @constCast(&[_]cfg.FieldDecl{
        .{ .name = "a", .type_ = .{ .primitive = .int32 } },
    }),
} };

test "validator accepts a union match over a concrete union (ir.md §12)" {
    const msg_ = try parseValidateWithDecls(
        \\module "use" {
        \\    func @msg(result: Result) -> str {
        \\    entry:
        \\        %tag: uint32 = read_tag %result
        \\        switch %tag { #0 -> arm_ok, #1 -> arm_err }
        \\    arm_ok:
        \\        %v: str = read_payload %result
        \\        %r1: str = construct %v
        \\        j join
        \\    arm_err:
        \\        %r2: str = const "err"
        \\        j join
        \\    join:
        \\        %m: str = phi [%r1, arm_ok], [%r2, arm_err]
        \\        ret %m
        \\    }
        \\}
    , &.{result_union});
    try std.testing.expect(msg_ == null);
}

test "validator rejects a read_field index out of range (ir.md §12)" {
    const msg_ = try parseValidateWithDecls(
        \\module "use" {
        \\    func @f(p: Pair) -> int32 {
        \\    entry:
        \\        %f: int32 = read_field %p, #1
        \\        ret %f
        \\    }
        \\}
    , &.{pair_struct});
    defer if (msg_) |m| std.testing.allocator.free(m);
    try std.testing.expect(msg_ != null);
    try std.testing.expect(std.mem.indexOf(u8, msg_.?, "names no field") != null);
}

test "validator rejects a read_field whose result type mismatches the field (ir.md §12)" {
    const msg_ = try parseValidateWithDecls(
        \\module "use" {
        \\    func @f(p: Pair) -> str {
        \\    entry:
        \\        %f: str = read_field %p, #0
        \\        ret %f
        \\    }
        \\}
    , &.{pair_struct});
    defer if (msg_) |m| std.testing.allocator.free(m);
    try std.testing.expect(msg_ != null);
    try std.testing.expect(std.mem.indexOf(u8, msg_.?, "expected its declared field type") != null);
}

test "validator rejects read_field and unpack_struct over a union base (ir.md §12)" {
    const msg_ = try parseValidateWithDecls(
        \\module "use" {
        \\    func @f(r: Result) -> int32 {
        \\    entry:
        \\        %f: int32 = read_field %r, #0
        \\        ret %f
        \\    }
        \\    func @g(r: Result) -> void {
        \\    entry:
        \\        %a: str = unpack_struct %r
        \\        ret
        \\    }
        \\}
    , &.{result_union});
    defer if (msg_) |m| std.testing.allocator.free(m);
    try std.testing.expect(msg_ != null);
}

test "validator rejects a construct with a mismatched payload arity (ir.md §12)" {
    const msg_ = try parseValidateWithDecls(
        \\module "use" {
        \\    func @f() -> Result {
        \\    entry:
        \\        %0: Result = construct #0
        \\        ret %0
        \\    }
        \\}
    , &.{result_union});
    defer if (msg_) |m| std.testing.allocator.free(m);
    try std.testing.expect(msg_ != null);
    try std.testing.expect(std.mem.indexOf(u8, msg_.?, "passes 0 arguments to the 1-payload") != null);
}

test "validator rejects unpack_variant and borrow_variant arity mismatches (ir.md §12)" {
    const msg_ = try parseValidateWithDecls(
        \\module "use" {
        \\    func @f(move r: Result) -> void {
        \\    entry:
        \\        %a: str, %b: str = unpack_variant %r, #0
        \\        ret
        \\    }
        \\    func @g(borrow r: Result) -> void {
        \\    entry:
        \\        %a: str, %b: str = borrow_variant %r, #0
        \\        ret
        \\    }
        \\}
    , &.{result_union});
    defer if (msg_) |m| std.testing.allocator.free(m);
    try std.testing.expect(msg_ != null);
    try std.testing.expect(std.mem.indexOf(u8, msg_.?, "defines 2 results, expected the variant's 1 payloads") != null);
}

test "validator rejects borrow_variant over a struct base (ir.md §12)" {
    const msg_ = try parseValidateWithDecls(
        \\module "use" {
        \\    func @f(p: Pair) -> void {
        \\    entry:
        \\        %a: int32 = borrow_variant %p, #0
        \\        ret
        \\    }
        \\}
    , &.{pair_struct});
    defer if (msg_) |m| std.testing.allocator.free(m);
    try std.testing.expect(msg_ != null);
    try std.testing.expect(std.mem.indexOf(u8, msg_.?, "type mismatch") != null);
}

test "validator rejects a non-exhaustive switch (ir.md §12)" {
    const msg_ = try parseValidateWithDecls(
        \\module "use" {
        \\    func @msg(result: Result) -> str {
        \\    entry:
        \\        %tag: uint32 = read_tag %result
        \\        switch %tag { #0 -> arm_ok }
        \\    arm_ok:
        \\        %v: str = read_payload %result
        \\        ret %v
        \\    }
        \\}
    , &.{result_union});
    defer if (msg_) |m| std.testing.allocator.free(m);
    try std.testing.expect(msg_ != null);
    try std.testing.expect(std.mem.indexOf(u8, msg_.?, "arms for the 2 variants") != null);
}

test "validator rejects projections over an opaque type (ir.md §12)" {
    const handle = cfg.TypeDecl{ .opaque_ = .{
        .name = "Handle",
        .module = "use",
        .ownership = .unique,
        .host_id = .{ .host_module = "use", .type_name = "Handle" },
    } };
    const msg_ = try parseValidateWithDecls(
        \\module "use" {
        \\    func @f(h: Handle) -> void {
        \\    entry:
        \\        %f: int32 = read_field %h, #0
        \\        ret
        \\    }
        \\    func @g() -> Handle {
        \\    entry:
        \\        %h: Handle = construct
        \\        ret %h
        \\    }
        \\}
    , &.{handle});
    defer if (msg_) |m| std.testing.allocator.free(m);
    try std.testing.expect(msg_ != null);
    try std.testing.expect(std.mem.indexOf(u8, msg_.?, "may not target an opaque type") != null);
}

test "validator accepts a read_field over a generic struct instantiation (ir.md §12)" {
    // The text form carries no type declarations or type arguments (ir.md
    // §10), so the test installs a generic `Pair[T, U]` declaration and
    // patches the parameter's named type to the `Pair[int32, str]`
    // instantiation; field #0 then substitutes to `int32`.
    const pair_gen = cfg.TypeDecl{ .struct_ = .{
        .name = "Pair",
        .module = "use",
        .type_params = @constCast(&[_][]const u8{ "T", "U" }),
        .ownership = .copy,
        .drop = null,
        .fields = @constCast(&[_]cfg.FieldDecl{
            .{ .name = "a", .type_ = .{ .param = "T" } },
            .{ .name = "b", .type_ = .{ .param = "U" } },
        }),
    } };
    var t = try cfg_parse.parseText(
        \\module "use" {
        \\    func @f(p: Pair) -> int32 {
        \\    entry:
        \\        %f: int32 = read_field %p, #0
        \\        ret %f
        \\    }
        \\}
    );
    defer t.arena.deinit();
    t.program.types[0] = pair_gen;
    t.program.funcs[0].values[0].type_ = .{ .named = .{ .id = 0, .args = @constCast(&[_]cfg.Type{ .{ .primitive = .int32 }, .{ .primitive = .str } }) } };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const m = try validate(&t.program, arena.allocator());
    try std.testing.expect(m == null);
}
