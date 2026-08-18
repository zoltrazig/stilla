//! Pass: local dead-instruction elimination (frontend.md §8.4). In: a
//! lowered `cfg.IrProgram` (after drop elision, so the unobservable drops
//! of Copy values are already gone). Out: the same program, with
//! every instruction whose results are unused, Copy, and produced
//! by a side-effect-free, non-consuming, non-trapping op removed.
//!
//! Destruction is observable only for unique values (type_shape classifies
//! any type with a user drop hook unique, and drop elision removes the
//! unobservable drops of Copy values), so a Copy result that
//! no instruction, terminator, or phi incoming reads can be removed
//! outright. The op must also be pure: calls, syscalls, `drop`,
//! `store_member`, `cleanup_*`, and the consuming destructures have
//! effects and are never candidates. Trapping ops — `div`/`rem` (divisor
//! zero), `num_cast` (range), `read_index`/`tail` (bounds), `read_field`/
//! `read_tuple` — are excluded: removing a dead trap changes observable
//! behavior. `read_payload` is included because the lowering emits it
//! only inside a switch arm whose tag was just dispatched
//! (cfg_lower_control, ir.md §5.3), so it cannot trap in lowered IR.
//!
//! Removal is iterated to a fixed point: removing an instruction can make
//! its operands dead too, which are then removed. Phis are left alone
//! (trivial phis are phi simplification's domain). Values are renumbered
//! in text order afterwards (ir.md §13). Allocations use the program's
//! backing allocator (the arena); the pass frees nothing.

const std = @import("std");
const cfg = @import("../cfg.zig");

/// The removable op set: side-effect-free, non-consuming, and — with the
/// two exclusions below — non-trapping. A comptime check ties the set to
/// the op schema: every candidate must be free of effects and consuming
/// semantics, so a drift here (removing a call or a move) is a compile
/// error, not a runtime surprise.
fn removable(tag: cfg.OpTag) bool {
    return switch (tag) {
        .const_,
        .module_ref,
        .fn_ref,
        .neg,
        .not_,
        .add,
        .sub,
        .mul,
        .concat,
        .eq,
        .ne,
        .lt,
        .le,
        .gt,
        .ge,
        .type_is,
        .read_tag,
        .read_payload,
        .copy,
        => true,
        else => false,
    };
}

comptime {
    for (std.meta.tags(cfg.OpTag)) |tag| {
        if (removable(tag)) {
            const info = cfg.opInfo(tag);
            std.debug.assert(!info.effects);
            std.debug.assert(info.consumes == .none);
        }
    }
}

/// Remove every dead removable instruction of the program.
pub fn deadInstr(program: *cfg.IrProgram, allocator: std.mem.Allocator) !void {
    for (program.funcs) |f| {
        try deadFunc(f, allocator);
    }
}

fn deadFunc(f: *cfg.IrFunc, allocator: std.mem.Allocator) !void {
    // use count per value; def map value -> defining instruction.
    var uses = std.AutoHashMapUnmanaged(*cfg.Value, u32){};
    defer uses.deinit(allocator);
    var defs = std.AutoHashMapUnmanaged(*cfg.Value, *cfg.Instr){};
    defer defs.deinit(allocator);
    for (f.blocks) |b| {
        for (b.instrs) |instr| {
            for (instr.results) |r| try defs.put(allocator, r, instr);
            var ops = std.ArrayList(*cfg.Value).empty;
            defer ops.deinit(allocator);
            try collectInstrOperands(instr, &ops, allocator);
            for (ops.items) |v| try bump(allocator, &uses, v);
        }
        var ops = std.ArrayList(*cfg.Value).empty;
        defer ops.deinit(allocator);
        try collectTermOperands(b.terminator, &ops, allocator);
        for (ops.items) |v| try bump(allocator, &uses, v);
    }

    // Seed the worklist with every dead removable instruction; removals
    // cascade through the def map.
    var work = std.ArrayList(*cfg.Instr).empty;
    defer work.deinit(allocator);
    var queued = std.AutoHashMapUnmanaged(*cfg.Instr, void){};
    defer queued.deinit(allocator);
    for (f.blocks) |b| {
        for (b.instrs) |instr| {
            if (isCandidate(instr) and resultsDead(&uses, instr)) {
                try work.append(allocator, instr);
                try queued.put(allocator, instr, {});
            }
        }
    }

    var removed = std.AutoHashMapUnmanaged(*cfg.Instr, void){};
    defer removed.deinit(allocator);
    var ops = std.ArrayList(*cfg.Value).empty;
    defer ops.deinit(allocator);
    while (work.pop()) |instr| {
        if (removed.contains(instr)) continue;
        if (!resultsDead(&uses, instr)) continue; // a use appeared? (stale entry)
        try removed.put(allocator, instr, {});
        ops.clearRetainingCapacity();
        try collectInstrOperands(instr, &ops, allocator);
        for (ops.items) |v| {
            const c = uses.get(v) orelse continue;
            if (c == 1) {
                try uses.put(allocator, v, 0);
                if (defs.get(v)) |def| {
                    if (!removed.contains(def) and !queued.contains(def) and isCandidate(def)) {
                        try work.append(allocator, def);
                        try queued.put(allocator, def, {});
                    }
                }
            } else if (c > 1) {
                try uses.put(allocator, v, c - 1);
            }
        }
    }

    // Rebuild the block instruction lists without the removed
    // instructions, and renumber the surviving values.
    for (f.blocks) |b| {
        var out = std.ArrayList(*cfg.Instr).empty;
        for (b.instrs) |instr| {
            if (!removed.contains(instr)) try out.append(allocator, instr);
        }
        b.instrs = try out.toOwnedSlice(allocator);
    }
    try cfg.renumberValues(f, allocator);
}

/// A removable candidate: op in the safe set and every result Copy.
fn isCandidate(instr: *const cfg.Instr) bool {
    if (instr.results.len == 0 or !removable(std.meta.activeTag(instr.op))) return false;
    for (instr.results) |r| {
        if ((r.ownership orelse .copy) == .unique) return false;
    }
    return true;
}

/// True when every result of `instr` has no remaining use.
fn resultsDead(uses: *const std.AutoHashMapUnmanaged(*cfg.Value, u32), instr: *const cfg.Instr) bool {
    for (instr.results) |r| {
        if ((uses.get(r) orelse 0) != 0) return false;
    }
    return true;
}

fn bump(allocator: std.mem.Allocator, uses: *std.AutoHashMapUnmanaged(*cfg.Value, u32), v: *cfg.Value) !void {
    const gop = try uses.getOrPut(allocator, v);
    if (!gop.found_existing) gop.value_ptr.* = 0;
    gop.value_ptr.* += 1;
}

/// The value operands of `instr` (phi incomings are counted by the
/// caller's walk of `f.blocks`; here the phi case is unreachable).
fn collectInstrOperands(instr: *const cfg.Instr, out: *std.ArrayList(*cfg.Value), allocator: std.mem.Allocator) !void {
    switch (instr.op) {
        .neg, .not_, .num_cast, .any_pack_copy, .any_pack_move, .any_unpack_copy, .any_unpack_move, .cleanup_arm, .cleanup_disarm, .cleanup_drop, .copy, .borrow, .move_, .tail, .unpack_struct, .unpack_tuple, .split_list, .read_tag, .read_payload, .drop_ => |v| try out.append(allocator, v),
        .unpack_variant => |uv| try out.append(allocator, uv.base),
        .borrow_variant => |bv| try out.append(allocator, bv.base),
        .type_is => |x| try out.append(allocator, x.value),
        .add, .sub, .mul, .div, .rem, .concat, .eq, .ne, .lt, .le, .gt, .ge => |x| {
            try out.append(allocator, x.a);
            try out.append(allocator, x.b);
        },
        .load_member => |x| try out.append(allocator, x.module),
        .store_member => |x| try out.append(allocator, x.value),
        .construct => |x| for (x.args) |a| try out.append(allocator, a),
        .read_field, .read_tuple => |x| try out.append(allocator, x.base),
        .read_index => |x| {
            try out.append(allocator, x.base);
            try out.append(allocator, x.index);
        },
        .call => |x| {
            if (x.callee == .value) try out.append(allocator, x.callee.value);
            for (x.args) |a| try out.append(allocator, a);
        },
        .syscall => |x| for (x.args) |a| try out.append(allocator, a),
        .const_, .module_ref, .fn_ref => {},
        .phi => |x| for (x.incoming) |inc| try out.append(allocator, inc.value),
    }
}

/// The value operands of a terminator.
fn collectTermOperands(term: cfg.Terminator, out: *std.ArrayList(*cfg.Value), allocator: std.mem.Allocator) !void {
    switch (term) {
        .ret => |v| if (v) |val| try out.append(allocator, val),
        .j => {},
        .br => |bc| try out.append(allocator, bc.cond),
        .@"switch" => |s| try out.append(allocator, s.disc),
        .tailcall => |tc| for (tc.args) |a| try out.append(allocator, a),
        .trap => {},
    }
}
