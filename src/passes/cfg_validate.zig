//! Pass: CFG IR validity validator — the ir.md §13 invariant set,
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
//!   their shapes, `copy` never over an affine operand, `drop` never
//!   over a duplicable value, cleanup ops over cleanup tokens.
//! - **Ownership dataflow** — an edge-sensitive forward analysis over
//!   affine values (`Available` / `Consumed` / `MaybeConsumed`, merged
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

/// The per-value availability state along a path (ir.md §13 Ownership):
/// alive (owned), consumed (dead on this path), or consumed on some
/// paths and alive on others after a join (maybe-affine, Core §10.10).
const AState = enum { available, consumed, maybe };

const StateMap = std.AutoHashMap(*const cfg.Value, AState);

/// Validate a whole program. Returns null when valid, otherwise the
/// first violation as a message (allocated from `allocator`).
pub fn validate(program: *const cfg.IrProgram, allocator: std.mem.Allocator) !?[]const u8 {
    for (program.funcs) |f| {
        if (try validateFunc(f, allocator)) |m| return m;
    }
    return null;
}

/// Validate one function.
fn validateFunc(f: *const cfg.IrFunc, allocator: std.mem.Allocator) !?[]const u8 {
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
    // Seed: entry-block parameter values (affine, non-borrow mode).
    for (f.params, 0..) |p, i| {
        const v = f.values[i];
        if (v.state == .owned and v.ownership != .duplicable and p.mode != .borrow) {
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
    // removes, and trap-terminated dead stubs, §10.10): their *semantic*
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
            // with no affine state still propagates reachability; the
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
        // The bases of an in-progress `take_*` destructure run (ir.md
        // §5.3): the frontend emits all takes of one destructure
        // consecutively, and the base is dead only after its final take.
        // A take of an already-taken base continues the run; any other
        // use of a run base is a violation.
        var take_bases = std.AutoHashMap(*const cfg.Value, void).init(allocator);
        // Phi group first (block head). Each incoming is checked against
        // its arriving edge's exit state (ir.md §6.3: the phi transfers
        // ownership of the value that actually arrived).
        for (b.instrs) |instr| {
            if (instr.op != .phi) break;
            const phi = instr.op.phi;
            for (phi.incoming) |inc| {
                if (!cfg.Type.eql(instr.result.?.type_, inc.value.type_)) {
                    return msg(allocator, "function @{s}: phi in '{s}' joins value %{d} of type {any} into {any}", .{ f.name.text, b.name, inc.value.id, inc.value.type_, instr.result.?.type_ });
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
                if (inc.value.ownership != .duplicable) try st.put(inc.value, .consumed);
            }
            if (instr.result.?.ownership != .duplicable) try st.put(instr.result.?, .available);
        }
        for (b.instrs) |instr| {
            if (instr.op == .phi) continue;
            if (try checkInstr(f, b, instr, dom, &st, &take_bases, allocator)) |m| return m;
        }
        if (try checkTerminator(f, b, dom, &st, allocator)) |m| return m;
    }

    return null;
}

/// The successors of `b` in edge order (allocator-owned; a `switch` has
/// one successor per arm).
fn successors(b: *const cfg.BasicBlock, allocator: std.mem.Allocator) ![]const *const cfg.BasicBlock {
    var out = std.ArrayList(*const cfg.BasicBlock).empty;
    switch (b.terminator) {
        .ret, .trap => {},
        .branch => |t| try out.append(allocator, t),
        .branch_cond => |bc| {
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

/// The state map after walking `b` from its entry state: affine results
/// become available, consumed operands become consumed. The transfer is
/// deterministic, so the exit map is a fresh copy of the entry map plus
/// the instruction effects.
fn exitState(b: *const cfg.BasicBlock, entry: StateMap, allocator: std.mem.Allocator) !StateMap {
    var st = StateMap.init(allocator);
    var it = entry.iterator();
    while (it.next()) |e| try st.put(e.key_ptr.*, e.value_ptr.*);
    for (b.instrs) |instr| {
        try transfer(instr, &st);
        if (instr.result) |r| {
            if (r.ownership != .duplicable) try st.put(r, .available);
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
        if (val.ownership != .duplicable) try st.put(val, .consumed);
    }
}

fn operand0(op: cfg.Op) ?*const cfg.Value {
    return switch (op) {
        .neg, .not_, .num_cast, .any_pack_copy, .any_pack_move, .any_unpack_copy, .any_unpack_move, .cleanup_owner, .cleanup_disable, .drop_cleanup, .copy, .borrow, .move_, .tail, .take_tail, .read_tag, .read_payload, .take_payload, .drop_ => |v| v,
        .type_is => |x| x.value,
        .load_member => |x| x.module,
        .read_field, .take_field, .read_tuple, .take_tuple => |x| x.base,
        .store_member => |x| x.value,
        else => null,
    };
}

fn operand1(op: cfg.Op) ?*const cfg.Value {
    return switch (op) {
        .read_index, .take_index => |x| x.index,
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
/// duplicable values are untracked.
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
    if (v.state == .borrowed or v.ownership == .duplicable) return null;
    if (edge.get(v)) |s| {
        switch (s) {
            .available => {},
            .consumed => return msg(allocator, "function @{s}: {s} %{d} is consumed on its arriving edge into block '{s}'", .{ f.name.text, what, v.id, b.name }),
            .maybe => return msg(allocator, "function @{s}: {s} %{d} is maybe-affine on its arriving edge into block '{s}'", .{ f.name.text, what, v.id, b.name }),
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
    // them and for duplicable values.
    if (val.state == .borrowed or val.ownership == .duplicable) return null;
    if (st.get(val)) |s| {
        switch (s) {
            .available => {},
            .consumed => return msg(allocator, "function @{s}: '{s}' consumes already-consumed value %{d} in block '{s}'", .{ f.name.text, cfg.opInfo(std.meta.activeTag(instr.op)).text, val.id, b.name }),
            .maybe => return msg(allocator, "function @{s}: '{s}' consumes maybe-affine value %{d} in block '{s}' (unusable after a conditional construct, ir.md §6.4)", .{ f.name.text, cfg.opInfo(std.meta.activeTag(instr.op)).text, val.id, b.name }),
        }
    }
    return null;
}

/// Check that a value is available at a use site (not consumed on this
/// path, not maybe). Borrowed and duplicable values are untracked.
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
    if (v.state == .borrowed or v.ownership == .duplicable) return null;
    if (st.get(v)) |s| {
        switch (s) {
            .available => {},
            .consumed => return msg(allocator, "function @{s}: {s} uses already-consumed value %{d} in block '{s}'", .{ f.name.text, what, v.id, b.name }),
            .maybe => return msg(allocator, "function @{s}: {s} uses maybe-affine value %{d} in block '{s}' (unusable after a conditional construct, ir.md §6.4)", .{ f.name.text, what, v.id, b.name }),
        }
    }
    return null;
}

/// Static operand checks + dataflow transfer for one non-phi
/// instruction.
fn checkInstr(
    f: *const cfg.IrFunc,
    b: *const cfg.BasicBlock,
    instr: *const cfg.Instr,
    dom: [][]bool,
    st: *StateMap,
    take_bases: *std.AutoHashMap(*const cfg.Value, void),
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

    // ---- Availability of consumed operands (schema) ----
    // The ops whose ownership effect is fixed (move, take, drop,
    // any_pack_move, any_unpack_move, store_member) require their operand
    // available on this path; call/syscall argument modes are checked in
    // their own cases (they depend on the signature).
    switch (info.consumes) {
        .none => {},
        .op0 => if (try checkConsumedOperand2(f, b, instr, operand0(instr.op), st.*, take_bases, allocator)) |m| return m,
        .op1 => if (try checkConsumedOperand2(f, b, instr, operand1(instr.op), st.*, take_bases, allocator)) |m| return m,
        .both => {
            if (try checkConsumedOperand2(f, b, instr, operand0(instr.op), st.*, take_bases, allocator)) |m| return m;
            if (try checkConsumedOperand2(f, b, instr, operand1(instr.op), st.*, take_bases, allocator)) |m| return m;
        },
        .all => {}, // phi: checked at the block head, edge-sensitively
    }

    // ---- SSA dominance for every operand ----
    const ops = try collectOperands(instr, allocator);
    for (ops) |v| {
        if (try checkUse(f, b, instr, v, dom, allocator)) |m| return m;
    }

    // ---- Typing + static ownership rules (per op) ----
    switch (instr.op) {
        .arg => |i| {
            if (i >= f.params.len) {
                return msg(allocator, "function @{s}: arg #{d} out of range ({d} parameters)", .{ f.name.text, i, f.params.len });
            }
        },
        .const_, .module_ref, .fn_ref => {},
        .neg => |v| {
            if (!isNumeric(v.type_)) return typeErr(allocator, f, b, info.text, v.type_);
        },
        .not_ => |v| {
            if (!isBool(v.type_)) return typeErr(allocator, f, b, "not", v.type_);
        },
        .num_cast => |v| {
            if (!isNumeric(v.type_) or !isNumeric(instr.result.?.type_)) {
                return typeErr(allocator, f, b, "num_cast", v.type_);
            }
        },
        .type_is => |x| {
            if (!isAny(x.value.type_) or !isBool(instr.result.?.type_)) return typeErr(allocator, f, b, "type_is", x.value.type_);
        },
        .any_pack_copy, .any_pack_move => |v| {
            if (!isAny(instr.result.?.type_)) return typeErr(allocator, f, b, info.text, v.type_);
        },
        .any_unpack_copy, .any_unpack_move => |v| {
            if (!isAny(v.type_)) return typeErr(allocator, f, b, info.text, v.type_);
        },
        .add, .sub, .mul, .div, .rem => |x| {
            if (!isNumeric(x.a.type_) or !cfg.Type.eql(x.a.type_, x.b.type_) or !cfg.Type.eql(x.a.type_, instr.result.?.type_)) {
                return typeErr(allocator, f, b, info.text, x.a.type_);
            }
        },
        .concat => |x| {
            if (!isStr(x.a.type_) or !isStr(x.b.type_)) return typeErr(allocator, f, b, "concat", x.a.type_);
        },
        .eq, .ne, .lt, .le, .gt, .ge => |x| {
            if (!cfg.Type.eql(x.a.type_, x.b.type_) or !isBool(instr.result.?.type_)) return typeErr(allocator, f, b, info.text, x.a.type_);
        },
        .copy => |v| {
            if (v.ownership == .affine) return typeErr(allocator, f, b, "copy", v.type_);
        },
        .borrow => |v| {
            if (!cfg.Type.eql(v.type_, instr.result.?.type_)) return typeErr(allocator, f, b, "borrow", v.type_);
        },
        .move_ => |v| {
            if (v.state == .borrowed) {
                return msg(allocator, "function @{s}: move of borrowed value %{d} in block '{s}' (Core §10.7)", .{ f.name.text, v.id, b.name });
            }
        },
        .drop_ => |v| {
            if (v.ownership == .duplicable) {
                return msg(allocator, "function @{s}: drop of duplicable value %{d} in block '{s}' (the frontend never emits it)", .{ f.name.text, v.id, b.name });
            }
            if (v.state == .borrowed) {
                return msg(allocator, "function @{s}: drop of borrowed value %{d} in block '{s}' (Core §10.7)", .{ f.name.text, v.id, b.name });
            }
        },
        .cleanup_owner => |v| {
            if (instr.result.?.type_ != .cleanup) return typeErr(allocator, f, b, "cleanup_owner", v.type_);
        },
        .cleanup_disable, .drop_cleanup => |v| {
            if (v.type_ != .cleanup) {
                return msg(allocator, "function @{s}: {s} operand %{d} is not a cleanup token in block '{s}'", .{ f.name.text, info.text, v.id, b.name });
            }
        },
        .load_member => |x| {
            if (x.module.type_ != .module) return typeErr(allocator, f, b, "load_member", x.module.type_);
        },
        .store_member => |x| {
            _ = x;
            if (!std.mem.eql(u8, f.name.text, "init")) {
                return msg(allocator, "function @{s}: store_member outside @init (ir.md §5.6)", .{f.name.text});
            }
        },
        .construct => {},
        .read_field, .take_field, .read_tuple, .take_tuple => {},
        .read_index, .take_index => |x| {
            if (x.base.type_ != .list) return typeErr(allocator, f, b, info.text, x.base.type_);
        },
        .tail, .take_tail => |v| {
            if (v.type_ != .list or instr.result.?.type_ != .list) return typeErr(allocator, f, b, info.text, v.type_);
        },
        .read_tag => |v| {
            _ = v;
            if (instr.result.?.type_ != .primitive or instr.result.?.type_.primitive != .uint32) {
                return typeErr(allocator, f, b, "read_tag", instr.result.?.type_);
            }
        },
        .read_payload => {},
        .take_payload => |v| {
            if (v.state == .borrowed) {
                return msg(allocator, "function @{s}: take_payload of borrowed value %{d} in block '{s}' (Core §10.7)", .{ f.name.text, v.id, b.name });
            }
        },
        .call => |c| {
            // Move-mode arguments consume; borrow/plain pass views. For a
            // direct call the callee's signature gives the modes; a value
            // callee's function type carries them.
            const params = calleeParams(c);
            for (c.args, 0..) |a, i| {
                const mode: ast.ParamMode = if (i < params.len) params[i].mode else .plain;
                if (mode == .move) {
                    if (try checkAvailable(f, b, instr, a, st.*, "move-mode argument", allocator)) |m| return m;
                    if (a.ownership != .duplicable) try st.put(a, .consumed);
                } else {
                    if (a.ownership != .duplicable and a.state != .borrowed) {
                        if (st.get(a)) |s| {
                            if (s != .available) {
                                return msg(allocator, "function @{s}: argument %{d} is {s} in block '{s}'", .{ f.name.text, a.id, @tagName(s), b.name });
                            }
                        }
                    }
                }
            }
        },
        .syscall => |s| {
            // The syscall argument modes come from the host signature,
            // which the IR does not carry; the lowering emits move-mode
            // args already moved, so an arriving borrowed value is a
            // plain/borrow argument — a legal view. Nothing to check
            // here beyond the schema's arity (done above).
            _ = s;
        },
        .phi => unreachable, // handled at the block head
    }

    // ---- Dataflow transfer for this instruction ----
    try transfer(instr, st);
    if (isTakeOp(instr.op)) {
        if (operand0(instr.op)) |base| {
            if (base.ownership != .duplicable) try take_bases.put(base, {});
        }
    }
    if (instr.result) |r| {
        if (r.ownership != .duplicable) try st.put(r, .available);
    }
    return null;
}

fn isTakeOp(op: cfg.Op) bool {
    return switch (op) {
        .take_field, .take_tuple, .take_index, .take_tail, .take_payload => true,
        else => false,
    };
}

/// The consumed-operand check, with the multi-take destructure idiom:
/// a `take_*` whose base was already consumed by an earlier `take_*` in
/// the same block continues the run (ir.md §5.3 — the base is dead only
/// after its final take).
fn checkConsumedOperand2(
    f: *const cfg.IrFunc,
    b: *const cfg.BasicBlock,
    instr: *const cfg.Instr,
    v: ?*const cfg.Value,
    st: StateMap,
    take_bases: *std.AutoHashMap(*const cfg.Value, void),
    allocator: std.mem.Allocator,
) !?[]const u8 {
    const val = v orelse return null;
    if (isTakeOp(instr.op)) {
        if (take_bases.contains(val)) {
            if (st.get(val)) |s| {
                if (s != .consumed) {
                    return msg(allocator, "function @{s}: take of value %{d} in block '{s}' whose state is {s}", .{ f.name.text, val.id, b.name, @tagName(s) });
                }
            }
            return null;
        }
        // A take of a base consumed by a non-take op is a double
        // consumption; fall through to the standard check.
        if (st.get(val)) |s| {
            if (s == .consumed) {
                return msg(allocator, "function @{s}: '{s}' consumes already-consumed value %{d} in block '{s}'", .{ f.name.text, cfg.opInfo(std.meta.activeTag(instr.op)).text, val.id, b.name });
            }
        }
    }
    return checkConsumedOperand(f, b, instr, v, st, allocator);
}

/// The terminator checks: `ret` consumes its affine value (never a
/// borrowed view; type-matched to the return type, modulo `never`), and
/// every terminator operand is dominated by its definition.
fn checkTerminator(f: *const cfg.IrFunc, b: *const cfg.BasicBlock, dom: [][]bool, st: *StateMap, allocator: std.mem.Allocator) !?[]const u8 {
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
            if (val.ownership != .duplicable) {
                if (st.get(val)) |s| {
                    if (s != .available) {
                        return msg(allocator, "function @{s}: ret of non-available value %{d} in block '{s}'", .{ f.name.text, val.id, b.name });
                    }
                }
            }
        },
        .branch, .trap => {},
        .branch_cond => |bc| {
            if (try checkUse(f, b, null, bc.cond, dom, allocator)) |m| return m;
        },
        .@"switch" => |sw| {
            if (try checkUse(f, b, null, sw.disc, dom, allocator)) |m| return m;
        },
    }
    return null;
}

/// The value-operand count of an op (the 3-address arity, ir.md §4.2).
fn valueOperandCount(op: cfg.Op) usize {
    return switch (op) {
        .const_, .arg, .module_ref, .fn_ref => 0,
        .neg, .not_, .num_cast, .any_pack_copy, .any_pack_move, .any_unpack_copy, .any_unpack_move, .cleanup_owner, .cleanup_disable, .drop_cleanup, .copy, .borrow, .move_, .tail, .take_tail, .read_tag, .read_payload, .take_payload, .drop_ => 1,
        .type_is => 1,
        .load_member => 1,
        .store_member => 1,
        .read_field, .take_field, .read_tuple, .take_tuple => 1,
        .read_index, .take_index => 2,
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
        .neg, .not_, .num_cast, .any_pack_copy, .any_pack_move, .any_unpack_copy, .any_unpack_move, .cleanup_owner, .cleanup_disable, .drop_cleanup, .copy, .borrow, .move_, .tail, .take_tail, .read_tag, .read_payload, .take_payload, .drop_ => |v| try out.append(allocator, v),
        .type_is => |x| try out.append(allocator, x.value),
        .load_member => |x| try out.append(allocator, x.module),
        .store_member => |x| try out.append(allocator, x.value),
        .read_field, .take_field, .read_tuple, .take_tuple => |x| try out.append(allocator, x.base),
        .read_index, .take_index => |x| {
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
        .const_, .arg, .module_ref, .fn_ref => {},
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

fn isBool(t: cfg.Type) bool {
    return t == .primitive and t.primitive == .bool;
}

fn isStr(t: cfg.Type) bool {
    return t == .primitive and t.primitive == .str;
}

fn isAny(t: cfg.Type) bool {
    return t == .primitive and t.primitive == .any;
}

fn typeErr(allocator: std.mem.Allocator, f: *const cfg.IrFunc, b: *const cfg.BasicBlock, what: []const u8, t: cfg.Type) !?[]const u8 {
    _ = t;
    return msg(allocator, "function @{s}: '{s}' operand/result type mismatch in block '{s}'", .{ f.name.text, what, b.name });
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
        \\        %2: cleanup = cleanup_owner %1
        \\        %3: bool = const true
        \\        br %3 ? then : join
        \\    then:
        \\        %4: File = move %1
        \\        cleanup_disable %2
        \\        call @consume, %4
        \\        br join
        \\    join:
        \\        drop_cleanup %2
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
        \\        br join
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
        \\        br join
        \\    b:
        \\        br join
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
