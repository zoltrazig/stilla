//! Pass: phi simplification (frontend.md §8.7). In: a lowered
//! `cfg.IrProgram` (after jump threading, which leaves single-incoming
//! phis behind). Out: the same program, with single-incoming phis, phis
//! whose incoming values are all identical, and self-referential trivial
//! phis (braun13cc.pdf Algorithm 3) forwarded to their operand and
//! removed.
//!
//! A phi whose block has a single predecessor takes that predecessor's
//! incoming value on every path, and a phi whose incoming values are all
//! the same value takes that value on every path — in both cases the phi
//! result is interchangeable with the shared value. A *trivial* phi
//! references only itself and one other value `v` any number of times
//! (`φ(v, vφ, vφ)`, e.g. a loop-carried value whose back edge passes the
//! header phi through unchanged); it, too, is interchangeable with `v`.
//! Rewriting every use of the result to the value and removing the phi is
//! safe because the value dominates the phi's block: it is defined in the
//! single predecessor (single-incoming case) or dominates every
//! predecessor (identical-incoming and trivial cases, since each incoming
//! value must dominate its edge) and therefore dominates every use of the
//! result (ir.md §4.3, §6.3).
//!
//! Forwarding is iterated to a fixed point: replacing one phi's incoming
//! values can make a phi that uses it trivial too (the paper's recursive
//! user walk, in map form). Incoming values are resolved through the map
//! before the triviality test, so the single scan the paper's recursion
//! needs is spread over at most as many iterations as there are phis.
//! A phi whose incoming values are all its own result (`φ(vφ, vφ)`) is
//! kept: it is unreachable or in the start block, and the IR has no
//! undefined value to forward it to (the paper's Undef case; the existing
//! "degenerate; keep it" behavior). Forwarding never closes a cycle in
//! the map (`%a = phi [%b], [%a]`, `%b = phi [%a], [%b]` would make
//! `resolve` loop) — such a pair is left untouched instead.
//!
//! Replacement chains resolve to their root, so a phi forwarded to a phi
//! collapses transitively; the acyclicity guard above makes the walk
//! terminate. Values are renumbered per function in text order afterwards
//! (ir.md §13). Allocations use the program's backing allocator (the
//! arena); the pass frees nothing.

const std = @import("std");
const cfg = @import("../cfg.zig");

/// Forward every redundant phi to its operand and remove it.
pub fn phiSimplify(program: *cfg.IrProgram, allocator: std.mem.Allocator) !void {
    for (program.funcs) |f| {
        try simplifyFunc(f, allocator);
    }
}

/// Simplify `f`'s redundant phis, remove them, and renumber.
fn simplifyFunc(f: *cfg.IrFunc, allocator: std.mem.Allocator) !void {
    // phi result → the value it is interchangeable with.
    var fwd = std.AutoHashMap(*cfg.Value, *cfg.Value).init(allocator);
    defer fwd.deinit();
    // Iterate to a fixed point: forwarding one phi can make a phi that
    // uses it trivial too (braun13cc.pdf Algorithm 3's recursive user
    // walk, in map form). The map only grows, so this is bounded by the
    // number of phis.
    var changed = true;
    while (changed) {
        changed = false;
        for (f.blocks) |b| {
            for (b.instrs) |instr| {
                if (instr.results.len == 0 or instr.op != .phi) continue;
                const phi = &instr.op.phi;
                if (fwd.contains(instr.results[0])) continue;
                if (trivialSource(&fwd, instr.results[0], phi)) |src| {
                    try fwd.put(instr.results[0], src);
                    changed = true;
                }
            }
        }
    }

    for (f.blocks) |b| {
        rewriteBlock(b, &fwd);
    }
    for (f.blocks) |b| {
        try removePhis(b, &fwd, allocator);
    }
    try cfg.renumberValues(f, allocator);
}

/// The value a trivial phi is interchangeable with, or `null` when it is
/// not trivial. A phi is trivial iff every resolved incoming value is the
/// phi's own result or one same value `v` (braun13cc.pdf Algorithm 3).
/// Incoming values are resolved through `fwd` first, so a phi whose
/// operand is a forwarded phi is tested with the value that forwarding
/// lands on.
///
/// An all-self phi (`φ(vφ, vφ)`) returns `null`: it is unreachable or in
/// the start block, and the IR has no undefined value to replace it with
/// (the paper's Undef case) — it is kept. Forwarding also never closes a
/// cycle in the map: `result` is only forwarded to `src` when `src` does
/// not resolve back to `result`, so `resolve` stays acyclic even on
/// hand-written IR (`%a = phi [%b], [%a]`, `%b = phi [%a], [%b]`).
fn trivialSource(
    fwd: *const std.AutoHashMap(*cfg.Value, *cfg.Value),
    result: *cfg.Value,
    phi: *const cfg.Phi,
) ?*cfg.Value {
    var same: ?*cfg.Value = null;
    for (phi.incoming) |inc| {
        const r = resolve(fwd, inc.value);
        if (r == result) continue; // self-reference
        if (same) |s| {
            if (r != s) return null; // merges two distinct values
        } else {
            same = r;
        }
    }
    const src = same orelse return null; // all-self: keep
    var cur = src;
    while (fwd.get(cur)) |nxt| {
        if (nxt == result) return null; // would close a cycle
        cur = nxt;
    }
    return src;
}

/// The ultimate non-phi value behind `v`: walk the forwarding chain to
/// its root. Chains are acyclic — `trivialSource` refuses to forward a
/// value that would close a cycle — so the walk terminates.
fn resolve(fwd: *const std.AutoHashMap(*cfg.Value, *cfg.Value), v: *cfg.Value) *cfg.Value {
    var cur = v;
    while (fwd.get(cur)) |nxt| cur = nxt;
    return cur;
}

/// Rewrite every operand of `b`'s instructions and terminator that is a
/// forwarded phi result to the phi's ultimate source.
fn rewriteBlock(b: *cfg.BasicBlock, fwd: *const std.AutoHashMap(*cfg.Value, *cfg.Value)) void {
    for (b.instrs) |instr| {
        rewriteInstr(instr, fwd);
    }
    switch (b.terminator) {
        .ret => |v| {
            if (v) |val| b.terminator.ret = resolve(fwd, val);
        },
        .j => {},
        .br => |*bc| bc.cond = resolve(fwd, bc.cond),
        .@"switch" => |*s| s.disc = resolve(fwd, s.disc),
        .tailcall => |*tc| for (tc.args) |*a| {
            a.* = resolve(fwd, a.*);
        },
        .trap => {},
    }
}

/// Rewrite the value operands of `instr` in place.
fn rewriteInstr(instr: *cfg.Instr, fwd: *const std.AutoHashMap(*cfg.Value, *cfg.Value)) void {
    switch (instr.op) {
        .neg, .not_, .num_cast, .any_pack_copy, .any_pack_move, .any_unpack_copy, .any_unpack_move, .cleanup_arm, .cleanup_disarm, .cleanup_drop, .copy, .borrow, .move_, .tail, .unpack_struct, .unpack_tuple, .split_list, .read_tag, .read_payload, .drop_ => |*v| {
            v.* = resolve(fwd, v.*);
        },
        .unpack_variant => |*uv| uv.base = resolve(fwd, uv.base),
        .borrow_variant => |*bv| bv.base = resolve(fwd, bv.base),
        .type_is => |*x| x.value = resolve(fwd, x.value),
        .add, .sub, .mul, .div, .rem, .concat, .eq, .ne, .lt, .le, .gt, .ge => |*x| {
            x.a = resolve(fwd, x.a);
            x.b = resolve(fwd, x.b);
        },
        .load_member => |*x| x.module = resolve(fwd, x.module),
        .store_member => |*x| x.value = resolve(fwd, x.value),
        .construct => |*x| {
            for (x.args) |*a| a.* = resolve(fwd, a.*);
        },
        .read_field, .read_tuple => |*x| x.base = resolve(fwd, x.base),
        .read_index => |*x| {
            x.base = resolve(fwd, x.base);
            x.index = resolve(fwd, x.index);
        },
        .call => |*x| {
            if (x.callee == .value) x.callee.value = resolve(fwd, x.callee.value);
            for (x.args) |*a| a.* = resolve(fwd, a.*);
        },
        .syscall => |*x| {
            for (x.args) |*a| a.* = resolve(fwd, a.*);
        },
        .phi => |*x| {
            for (x.incoming) |*inc| inc.value = resolve(fwd, inc.value);
        },
        .const_, .module_ref, .fn_ref => {},
    }
}

/// Drop every forwarded phi from `b`'s instruction list. All of a
/// forwarded phi's uses were rewritten, so the instruction is dead.
fn removePhis(b: *cfg.BasicBlock, fwd: *const std.AutoHashMap(*cfg.Value, *cfg.Value), allocator: std.mem.Allocator) !void {
    var out = std.ArrayList(*cfg.Instr).empty;
    for (b.instrs) |instr| {
        // Only phis are ever forwarded, and a phi has exactly one
        // result; a forwarded phi is dead.
        if (instr.op == .phi and instr.results.len > 0 and fwd.contains(instr.results[0])) continue;
        try out.append(allocator, instr);
    }
    b.instrs = try out.toOwnedSlice(allocator);
}
