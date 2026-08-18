//! Pass: drop lowering — post-optimization structural drop expansion
//! (ir.md §6.4 "drop hooks" / §6.3, Runtime §6.2–§6.3). In: an optimized
//! `cfg.IrProgram` plus the phase-1 `ModuleGraph`. Out: the same program
//! with every `drop` whose destruction is statically expressible in the
//! CFG expanded in place, so the only `drop` instructions that reach the
//! runtime are the ones it must dispatch dynamically:
//!
//! - opaque host nominal types — `host_drop(host_id, value)` (Runtime
//!   §6.6); the host owns the payload, the IR cannot expand it;
//! - the `hostdata` primitive — host disposal of an opaque payload
//!   (Runtime §3.4);
//! - `list[T]` — element count is dynamic; element destruction is a
//!   runtime loop (Runtime §6.3);
//! - `any` — the payload type is a runtime tag; destruction dispatches on
//!   it (Runtime §6.3).
//!
//! Every other destruction is expanded into explicit CFG operations at
//! the drop's program point (the prescribed destruction point is
//! unchanged — ir.md §6.4, "no pass moves destruction earlier"):
//!
//! - a struct drop becomes, in order: a direct `call` of the struct's
//!   hidden drop-hook function (when the declaration has a hook — the
//!   hook runs while all fields are valid, Runtime §6.2), an
//!   `unpack_struct` consuming the value, and the per-field drops in
//!   reverse declaration order — recursively expanded; *Copy* fields
//!   destroy nothing and get no drop;
//! - a tuple drop becomes `unpack_tuple` plus reverse-element drops;
//! - a `box[T]` drop becomes `builtin#unbox` plus a drop of the contained
//!   value (Runtime §6.3 "destroy the contained value");
//! - a union drop becomes `read_tag` + a `switch` whose per-variant arms
//!   `unpack_variant` the active payload and destroy it in reverse payload
//!   order (Runtime §6.3 "only the active union variant is destroyed").
//!   A payload-less variant destroys nothing and is a bare `j` to the
//!   join — matching the existing consuming-match lowering.
//!
//! The pass needs the phase-1 module graph (the IR type environment is
//! name-only, ir.md §11): field/variant types and ownership resolve
//! through the graph, and generic instantiations substitute their type
//! arguments (`moduleinfo.substParams`). It runs after the optimizer —
//! the optimizer never sees the expanded form, and the expansion is
//! validated by the frontend afterwards (ir.md §13).
//!
//! Block surgery: a union expansion splits its block — the read_tag and
//! the switch stay, the arm blocks and a join block are created, and the
//! original block's remaining instructions and terminator move to the
//! join. Successors of the split block have their predecessor (and phi
//! incoming) pointers redirected `block → join`. New blocks are appended
//! to the function; values are renumbered at the end (ir.md §4.1). The
//! `cleanup_arm` / `cleanup_disarm` / `cleanup_drop` family is never
//! touched: a cleanup token's payload liveness is runtime state
//! (ir.md §6.4), and expansion into flag stores is a backend matter.

const std = @import("std");
const ast = @import("../ast.zig");
const cfg = @import("../cfg.zig");
const moduleinfo = @import("../moduleinfo.zig");
const type_resolve = @import("type_resolve.zig");

const ModuleInfo = moduleinfo.ModuleInfo;
const TypeMember = moduleinfo.TypeMember;

/// A resolved type declaration: the module that declares it (the context
/// for written-name lookups inside field/variant types) and the member.
const DeclRef = struct {
    module: *ModuleInfo,
    member: *TypeMember,
};

/// The per-function state of the expansion.
const Ctx = struct {
    resolve: moduleinfo.Resolve,
    program: *cfg.IrProgram,
    /// TypeId → declaring module + member (aliases expanded; null when the
    /// id does not name a graph declaration).
    decls: []?DeclRef,
    allocator: std.mem.Allocator,
    /// The declaring module of the function under expansion — the fallback
    /// lookup context for structural (`tuple`/`box`) ownership.
    f_module: *ModuleInfo,
    /// Monotonic value-id source (ids are renumbered at the end anyway).
    next_value_id: u32,
    /// Monotonic block-id source.
    next_block_id: u32,
    /// Every block name in the function plus names we have minted.
    names: std.StringHashMapUnmanaged(void),
    /// The function's block list, rebuilt as new blocks are appended.
    blocks: std.ArrayListUnmanaged(*cfg.BasicBlock),
    /// Blocks still to scan for drops (the original list; joins created
    /// by a split are appended).
    work: std.ArrayListUnmanaged(*cfg.BasicBlock),
    /// Block-name counter for minting unique `drop_*` labels.
    name_n: u32 = 0,
};

/// One block under construction: the block, its instruction list, and
/// whether a union expansion terminated it with a `switch` (in which case
/// continuation proceeds in a newly created join block).
const Seq = struct {
    c: *Ctx,
    b: *cfg.BasicBlock,
    out: *std.ArrayListUnmanaged(*cfg.Instr),
    branching: bool = false,

    fn appendInstr(seq: *Seq, instr: *cfg.Instr) !void {
        try seq.out.append(seq.c.allocator, instr);
    }

    /// Create an instruction defining `result_types` values, append it,
    /// and return the results. `op` must be an op the schema classifies
    /// as producing owned results (or a pure effect with zero result
    /// types — `drop`, a void `call`, `store_member`, …).
    fn appendOp(seq: *Seq, span: ast.Span, op: cfg.Op, result_types: []const cfg.Type) ![]*cfg.Value {
        const c = seq.c;
        const results = try c.allocator.alloc(*cfg.Value, result_types.len);
        for (result_types, 0..) |t, i| {
            const v = try c.allocator.create(cfg.Value);
            v.* = .{
                .id = c.next_value_id,
                .span = span,
                .type_ = t,
                .ownership = moduleinfo.ownershipOf(c.resolve, c.f_module, t),
                .state = .owned,
                .origin = null,
                .def = null,
            };
            c.next_value_id += 1;
            results[i] = v;
        }
        const instr = try c.allocator.create(cfg.Instr);
        instr.* = .{ .span = span, .results = results, .op = op };
        for (results) |r| r.def = instr;
        try seq.out.append(c.allocator, instr);
        return results;
    }

    fn setTerminator(seq: *Seq, term: cfg.Terminator) void {
        seq.b.terminator = term;
    }

    /// Freeze the block's instruction list.
    fn finish(seq: *Seq) !void {
        seq.b.instrs = try seq.out.toOwnedSlice(seq.c.allocator);
    }

    /// Mint a fresh block, switch the sequence to it, and return it.
    fn newBlock(seq: *Seq) !*cfg.BasicBlock {
        const c = seq.c;
        var name: []const u8 = try std.fmt.allocPrint(c.allocator, "drop_{d}", .{c.name_n});
        c.name_n += 1;
        while (c.names.contains(name)) {
            name = try std.fmt.allocPrint(c.allocator, "drop_{d}", .{c.name_n});
            c.name_n += 1;
        }
        const b = try c.allocator.create(cfg.BasicBlock);
        b.* = .{
            .id = c.next_block_id,
            .span = seq.b.span,
            .name = name,
            .instrs = &.{},
            .terminator = undefined,
            .preds = &.{},
        };
        c.next_block_id += 1;
        try c.names.put(c.allocator, name, {});
        try c.blocks.append(c.allocator, b);
        const out = try c.allocator.create(std.ArrayListUnmanaged(*cfg.Instr));
        out.* = .empty;
        seq.b = b;
        seq.out = out;
        seq.branching = false;
        return b;
    }
};

/// Lower every `drop` in `program` that the CFG can express, leaving only
/// the dynamically-dispatched drops (opaque, `hostdata`, `list`, `any`).
/// Runs after the optimizer; the frontend re-validates the result.
pub fn lowerDrop(program: *cfg.IrProgram, graph: *moduleinfo.ModuleGraph, allocator: std.mem.Allocator) !void {
    const resolve = moduleinfo.resolveOf(graph);
    const decls = try collectDecls(resolve, graph, allocator);
    defer allocator.free(decls);
    for (program.funcs) |f| try lowerFunc(resolve, program, graph, decls, f, allocator);
}

/// Build the TypeId → declaration map (the interner assigns ids to
/// qualified names; the graph's per-module type members carry the decls).
fn collectDecls(resolve: moduleinfo.Resolve, graph: *moduleinfo.ModuleGraph, allocator: std.mem.Allocator) ![]?DeclRef {
    const n = graph.type_interner.to_name.items.len;
    const out = try allocator.alloc(?DeclRef, n);
    @memset(out, null);
    for (graph.modules) |info| {
        for (info.types) |*tm| {
            if (tm.decl == .alias) continue; // aliases expand at resolution
            const full = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ info.specifier, tm.name.text });
            const id = resolve.type_ids.?.idOf(full) orelse continue;
            out[id] = .{ .module = info, .member = tm };
        }
    }
    return out;
}

fn lowerFunc(resolve: moduleinfo.Resolve, program: *cfg.IrProgram, graph: *moduleinfo.ModuleGraph, decls: []?DeclRef, f: *cfg.IrFunc, allocator: std.mem.Allocator) !void {
    const f_module = blk: {
        if (f.module_spec) |spec| {
            if (resolve.module(spec)) |m| break :blk m;
        }
        break :blk graph.entry;
    };
    var max_v: u32 = 0;
    for (f.values) |v| max_v = @max(max_v, v.id);
    var max_b: u32 = 0;
    for (f.blocks) |b| max_b = @max(max_b, b.id);
    var c = Ctx{
        .resolve = resolve,
        .program = program,
        .decls = decls,
        .allocator = allocator,
        .f_module = f_module,
        .next_value_id = max_v + 1,
        .next_block_id = max_b + 1,
        .names = .empty,
        .blocks = .empty,
        .work = .empty,
    };
    defer c.names.deinit(allocator);
    defer c.blocks.deinit(allocator);
    defer c.work.deinit(allocator);
    for (f.blocks) |b| {
        try c.blocks.append(allocator, b);
        try c.work.append(allocator, b);
        try c.names.put(allocator, b.name, {});
    }
    var wi: usize = 0;
    while (wi < c.work.items.len) : (wi += 1) {
        try processBlock(&c, c.work.items[wi]);
    }
    f.blocks = try c.blocks.toOwnedSlice(allocator);
    try cfg.renumberValues(f, allocator);
}

/// Whether a `drop` of a value of type `t` should be expanded by this
/// pass (vs. kept as a single runtime instruction).
fn expandable(c: *Ctx, t: cfg.Type) bool {
    return switch (t) {
        .named => |n| blk: {
            const ref = c.decls[n.id] orelse break :blk false;
            break :blk switch (ref.member.decl) {
                .struct_, .union_ => true,
                .opaque_, .alias => false,
            };
        },
        .tuple, .box => true,
        else => false,
    };
}

/// Rewrite every drop in `b`. A straight-line expansion (struct, tuple,
/// box) splices in place; a union expansion terminates `b` with a
/// `switch`, moves the remainder to a join block, and queues the join for
/// scanning.
fn processBlock(c: *Ctx, b: *cfg.BasicBlock) !void {
    var out: std.ArrayListUnmanaged(*cfg.Instr) = .empty;
    var i: usize = 0;
    while (i < b.instrs.len) : (i += 1) {
        const instr = b.instrs[i];
        const v = switch (instr.op) {
            .drop_ => |x| x,
            else => null,
        };
        if (v) |val| {
            if (expandable(c, val.type_)) {
                // The block's terminator before the expansion: a union
                // expansion replaces it with a `switch` and moves the
                // original terminator to the join block. The remainder of
                // the original instruction list also moves there —
                // captured before the expansion, because the union case
                // freezes `b.instrs` in place.
                const old_term = b.terminator;
                const rest = b.instrs[i + 1 ..];
                var seq = Seq{ .c = c, .b = b, .out = &out };
                try emitDestroy(&seq, val);
                if (seq.branching) {
                    // `b` was terminated by the union's switch inside
                    // emitDestroy and its instruction list frozen; the
                    // block's remainder and terminator move to the join.
                    for (rest) |r| try seq.appendInstr(r);
                    seq.setTerminator(old_term);
                    try seq.finish();
                    // Redirect the successors that used to follow `b`
                    // (its *original* terminator — `b`'s terminator is
                    // now the union switch).
                    try redirectSuccessors(c, b, old_term, seq.b);
                    try c.work.append(c.allocator, seq.b);
                    return;
                }
                // Straight-line: the expansion is already in `out`; keep
                // scanning the original instructions after the drop.
                continue;
            }
        }
        try out.append(c.allocator, instr);
    }
    b.instrs = try out.toOwnedSlice(c.allocator);
}

/// Re-point every edge `b → successor` (per `old_term`, the terminator
/// `b` had before the expansion) to `join`: the successor's pred list and
/// its phis' incoming pred pointers (the incoming values are unchanged —
/// they are the same values `b` would have delivered).
fn redirectSuccessors(c: *Ctx, b: *cfg.BasicBlock, old_term: cfg.Terminator, join: *cfg.BasicBlock) !void {
    const allocator = c.allocator;
    const targets = switch (old_term) {
        .j => |t| &.{t},
        .br => |bc| &.{ bc.then_, bc.else_ },
        .@"switch" => |s| blk: {
            var ts = std.ArrayListUnmanaged(*cfg.BasicBlock).empty;
            defer ts.deinit(allocator);
            for (s.arms) |arm| try ts.append(allocator, arm.block);
            break :blk try ts.toOwnedSlice(allocator);
        },
        .ret, .tailcall, .trap => &.{},
    };
    for (targets) |s| {
        var preds = std.ArrayListUnmanaged(*cfg.BasicBlock).empty;
        defer preds.deinit(allocator);
        for (s.preds) |p| try preds.append(allocator, if (p == b) join else p);
        s.preds = try preds.toOwnedSlice(allocator);
        for (s.instrs) |instr| {
            if (instr.op != .phi) continue;
            const phi = &instr.op.phi;
            var incoming = std.ArrayListUnmanaged(cfg.PhiIn).empty;
            defer incoming.deinit(allocator);
            for (phi.incoming) |inc| {
                try incoming.append(allocator, .{ .value = inc.value, .pred = if (inc.pred == b) join else inc.pred });
            }
            phi.incoming = try incoming.toOwnedSlice(allocator);
        }
    }
}

/// Emit the destruction sequence for `v` into the current sequence,
/// recursing through components. `v`'s type must be unique (the frontend
/// never drops *Copy* values; the elision pass removes them).
fn emitDestroy(seq: *Seq, v: *cfg.Value) error{OutOfMemory}!void {
    const span = v.span;
    switch (v.type_) {
        .primitive => |k| switch (k) {
            // `hostdata` (host disposal) and `any` (tag-dispatched) stay.
            .hostdata, .any => _ = try seq.appendOp(span, .{ .drop_ = v }, &.{}),
            else => {}, // Copy — never dropped by the frontend; defensive.
        },
        // Dynamic or deferred — stays a single runtime instruction.
        .list, .param => _ = try seq.appendOp(span, .{ .drop_ = v }, &.{}),
        .function, .module, .cleanup => {}, // Copy — defensive.
        .box => |inner| {
            // `builtin#unbox` consumes the box at runtime (Runtime §4.6)
            // even though the syscall schema models `.consumes = .none`
            // (call modes come from the host signature, which the IR
            // does not carry) — so the expanded CFG leaves the box
            // unconsumed in the ownership dataflow, matching the
            // frontend's own `unbox` lowering. Do not "fix" this: the
            // box is runtime-consumed, and a `move` would be a second
            // consumption.
            const args = try seq.c.allocator.alloc(*cfg.Value, 1);
            args[0] = v;
            const r = try seq.appendOp(span, .{ .syscall = .{ .span = span, .target = .{ .builtin = .unbox }, .args = args, .ret = inner.* } }, &.{inner.*});
            try emitDestroy(seq, r[0]);
        },
        .tuple => |elems| {
            const results = try seq.appendOp(span, .{ .unpack_tuple = v }, elems);
            var idx = elems.len;
            while (idx > 0) {
                idx -= 1;
                if (moduleinfo.ownershipOf(seq.c.resolve, seq.c.f_module, elems[idx]) == .unique) {
                    try emitDestroy(seq, results[idx]);
                }
            }
        },
        .named => |n| {
            const ref = seq.c.decls[n.id] orelse {
                // An unknown declaration — keep the drop (defensive).
                _ = try seq.appendOp(span, .{ .drop_ = v }, &.{});
                return;
            };
            switch (ref.member.decl) {
                // Host-backed opaque — the host destructor dispatches
                // (`host_drop(host_id, value)`); never expandable.
                .opaque_ => _ = try seq.appendOp(span, .{ .drop_ = v }, &.{}),
                .struct_ => |s| try emitStructDrop(seq, v, ref, n.args, s, span),
                .union_ => |u| try emitUnionDrop(seq, v, ref, n.args, u, span),
                .alias => unreachable, // aliases expand at resolution
            }
        },
    }
}

/// A struct drop: hook call (when declared), `unpack_struct`, then
/// per-field drops in reverse declaration order (*Copy* fields skip).
fn emitStructDrop(seq: *Seq, v: *cfg.Value, ref: DeclRef, args: []const cfg.Type, s: *const ast.StructDef, span: ast.Span) error{OutOfMemory}!void {
    // The instantiated field types (a generic declaration's fields
    // reference its type parameters; substitute the instantiation's
    // args). Resolved before anything is emitted: an unresolvable field
    // (defensive; a checked program always resolves) keeps the drop
    // unexpanded instead of half-expanding it.
    var ftypes = std.ArrayListUnmanaged(cfg.Type).empty;
    defer ftypes.deinit(seq.c.allocator);
    for (s.fields) |*fd| {
        const ft = moduleinfo.resolveType(seq.c.resolve, ref.module, &fd.type_) orelse {
            _ = try seq.appendOp(span, .{ .drop_ = v }, &.{});
            return;
        };
        const ft_sub = type_resolve.substParams(seq.c.allocator, s.type_params, args, ft);
        try ftypes.append(seq.c.allocator, ft_sub);
    }
    if (s.drop) |_| {
        // The hook runs while all fields remain valid (Runtime §6.2), so
        // it is called on the whole value before the unpack; the borrow
        // view leaves the value owned for the destructure.
        const qname = try std.fmt.allocPrint(seq.c.allocator, "{s}.{s}.drop", .{ ref.module.specifier, s.name.text });
        const func = findFunc(seq.c.program, qname);
        const cargs = try seq.c.allocator.alloc(*cfg.Value, 1);
        cargs[0] = v;
        _ = try seq.appendOp(span, .{ .call = .{ .callee = .{ .direct = .{ .name = qname, .func = func } }, .args = cargs } }, &.{});
    }
    const results = try seq.appendOp(span, .{ .unpack_struct = v }, ftypes.items);
    var idx = ftypes.items.len;
    while (idx > 0) {
        idx -= 1;
        if (moduleinfo.ownershipOf(seq.c.resolve, ref.module, ftypes.items[idx]) == .unique) {
            try emitDestroy(seq, results[idx]);
        }
    }
}

/// A union drop: `read_tag`, a `switch` over the variants, per-variant
/// arms destroying the active payload (reverse payload order), converging
/// on a join block that continues the sequence.
fn emitUnionDrop(seq: *Seq, v: *cfg.Value, ref: DeclRef, args: []const cfg.Type, u: *const ast.UnionDef, span: ast.Span) error{OutOfMemory}!void {
    // Pre-resolve every variant's payload types before emitting anything
    // (same defensive reasoning as the struct case).
    const ptypes_of = try seq.c.allocator.alloc([]const cfg.Type, u.variants.len);
    defer seq.c.allocator.free(ptypes_of);
    for (u.variants, 0..) |*vari, vi| {
        if (vari.types) |vtypes| {
            var ptypes = std.ArrayListUnmanaged(cfg.Type).empty;
            defer ptypes.deinit(seq.c.allocator);
            for (vtypes) |*vt| {
                const pt = moduleinfo.resolveType(seq.c.resolve, ref.module, vt) orelse {
                    _ = try seq.appendOp(span, .{ .drop_ = v }, &.{});
                    return;
                };
                const pt_sub = type_resolve.substParams(seq.c.allocator, u.type_params, args, pt);
                try ptypes.append(seq.c.allocator, pt_sub);
            }
            ptypes_of[vi] = try ptypes.toOwnedSlice(seq.c.allocator);
        } else {
            ptypes_of[vi] = &.{};
        }
    }

    const tag = (try seq.appendOp(span, .{ .read_tag = v }, &.{.{ .primitive = .uint32 }}))[0];
    seq.branching = true;
    try seq.finish(); // the current block ends with the switch below
    const switch_target = seq.b;

    var arms = std.ArrayListUnmanaged(cfg.SwitchArm).empty;
    defer arms.deinit(seq.c.allocator);
    var finals = std.ArrayListUnmanaged(*cfg.BasicBlock).empty;
    defer finals.deinit(seq.c.allocator);
    // The join must exist before the arms' final blocks branch to it.
    var join_seq = seq.*;
    _ = try join_seq.newBlock();

    for (u.variants, 0..) |_, vi| {
        var arm_seq = seq.*;
        _ = try arm_seq.newBlock();
        const entry = arm_seq.b;
        if (ptypes_of[vi].len > 0) {
            const payloads = try arm_seq.appendOp(span, .{ .unpack_variant = .{ .base = v, .tag = @intCast(vi) } }, ptypes_of[vi]);
            var pi = ptypes_of[vi].len;
            while (pi > 0) {
                pi -= 1;
                if (moduleinfo.ownershipOf(seq.c.resolve, ref.module, ptypes_of[vi][pi]) == .unique) {
                    try emitDestroy(&arm_seq, payloads[pi]);
                }
            }
        }
        try arm_seq.finish(); // freezes the arm's final block
        try arms.append(seq.c.allocator, .{ .tag = @intCast(vi), .block = entry });
        try finals.append(seq.c.allocator, arm_seq.b);
    }

    const join = join_seq.b;
    for (finals.items) |fin| fin.terminator = .{ .j = join };
    join.preds = try finals.toOwnedSlice(seq.c.allocator);
    for (arms.items) |arm| {
        const arm_preds = try seq.c.allocator.alloc(*cfg.BasicBlock, 1);
        arm_preds[0] = switch_target;
        arm.block.preds = arm_preds;
    }
    switch_target.terminator = .{ .@"switch" = .{ .disc = tag, .arms = try arms.toOwnedSlice(seq.c.allocator) } };
    // Continuation proceeds in the join.
    seq.b = join;
    seq.out = join_seq.out;
}

/// The hidden drop-hook function for a struct, when lowered.
fn findFunc(program: *cfg.IrProgram, name: []const u8) ?*cfg.IrFunc {
    for (program.funcs) |f| {
        if (std.mem.eql(u8, f.name.text, name)) return f;
    }
    return null;
}
