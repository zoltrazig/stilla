//! Pass: the typed lowering layer (Layer A of the CFG → LLIR
//! boundary). The emitter reads a value's type only long enough to pick
//! the typed opcode (`add.i32`/`shr.u64`/…) — the opcode carries the
//! full rep, computes at that width, and self-canonicalizes its result
//! cell (Instruction Set §4), so one arithmetic instruction is exactly
//! one record. There is no value-form (top-bits) machinery in v11: the
//! canonical-cell contract is uniform across producers (a typed opcode,
//! a cast, or a `const` canonicalizes), so no canonicalization records
//! exist and nothing needs to track a cell's extension state.
//!
//! What remains here is the typed-op view (the atomic arithmetic /
//! cast nodes and their printer) and the immediate-fusion helpers the
//! expander-adjacent fusion pass shares.

const std = @import("std");
const cfg = @import("stilla").cfg;
const meta = @import("stilla").meta;
const llir = @import("stilla").llir;
const ast = @import("stilla").ast;

/// A typed lowering op (Layer A): one arithmetic / cast choice,
/// atomic. `type_` is the operand type; `result_type` is the
/// result type (only meaningful for a cast, where the CFG's
/// `num_cast` target differs from the operand type). `b` is null for
/// the unary arithmetic ops.
pub const TypedOp = struct {
    kind: llir.TypedKind,
    type_: meta.Type,
    result_type: meta.Type,
    a: *const cfg.Value,
    b: ?*const cfg.Value,
    result: *const cfg.Value,
};

/// The rep suffix of an arithmetic primitive type, or null for a
/// non-arithmetic type (the typed layer only carries arithmetic ops).
fn repName(t: meta.Type) ?[]const u8 {
    return switch (t) {
        .primitive => |k| switch (k) {
            .int32 => "i32",
            .uint32 => "u32",
            .int64 => "i64",
            .uint64 => "u64",
            .float32 => "f32",
            .float64 => "f64",
            else => null,
        },
        else => null,
    };
}

/// The typed-layer spelling of a kind (the typed family names and the
/// cast family).
fn kindName(kind: llir.TypedKind) []const u8 {
    return switch (kind) {
        .add => "add",
        .sub => "sub",
        .mul => "mul",
        .div => "div",
        .rem => "rem",
        .shl => "shl",
        .shr => "shr",
        .bitand => "and",
        .bitor => "or",
        .bitxor => "xor",
        .neg => "neg",
        .cast => "cvt",
        .abs => "abs",
        .min => "min",
        .max => "max",
        .clz => "clz",
        .popcount => "popcount",
    };
}

/// Build the Layer A typed-op list for one function: the arithmetic and
/// cast instructions, each as one atomic typed node. Comparisons and
/// other non-arithmetic instructions are skipped — they are not part of
/// the typed lowering boundary.
pub fn typedOps(allocator: std.mem.Allocator, func: *const cfg.IrFunc) error{OutOfMemory}![]TypedOp {
    var out = std.ArrayList(TypedOp).empty;
    for (func.blocks) |blk| {
        for (blk.instrs) |ins| {
            if (ins.results.len == 0) continue;
            const kind: llir.TypedKind = switch (llir.lower(std.meta.activeTag(ins.op))) {
                .typed => |k| k,
                else => continue, // not an arithmetic/cast op
            };
            const result = ins.results[0];
            const a: *const cfg.Value = switch (ins.op) {
                .neg, .abs, .clz, .popcount, .num_cast => |v| v,
                .add, .sub, .mul, .div, .rem, .min, .max, .shl, .shr, .bitand, .bitor, .bitxor => |bin| bin.a,
                else => unreachable,
            };
            const b: ?*const cfg.Value = switch (ins.op) {
                .neg, .abs, .clz, .popcount, .num_cast => null,
                .add, .sub, .mul, .div, .rem, .min, .max, .shl, .shr, .bitand, .bitor, .bitxor => |bin| bin.b,
                else => unreachable,
            };
            try out.append(allocator, .{
                .kind = kind,
                .type_ = a.type_,
                .result_type = result.type_,
                .a = a,
                .b = b,
                .result = result,
            });
        }
    }
    return out.toOwnedSlice(allocator);
}

/// Print one function's typed layer: one `%d: <type> = <op> <a>, <b>`
/// line per arithmetic/cast instruction. The op spelling carries
/// the type rep (`add.i32`, `cvt.i32.u32`) — the same spelling the
/// LLIR opcode carries. This is the typed-assembly printer: it renders
/// what Layer A sees.
pub fn printTyped(allocator: std.mem.Allocator, func: *const cfg.IrFunc) error{OutOfMemory}![]u8 {
    const ops = try typedOps(allocator, func);
    defer allocator.free(ops);
    var out = std.ArrayList(u8).empty;
    for (ops) |op| {
        const srep = repName(op.type_) orelse "?";
        const drep = repName(op.result_type) orelse "?";
        const name = if (op.kind == .cast)
            try std.fmt.allocPrint(allocator, "cvt.{s}.{s}", .{ srep, drep })
        else
            try std.fmt.allocPrint(allocator, "{s}.{s}", .{ kindName(op.kind), srep });
        defer allocator.free(name);
        var buf: [128]u8 = undefined;
        const head = std.fmt.bufPrint(&buf, "%{d}: {s} = {s} %{d}", .{ op.result.id, drep, name, op.a.id }) catch unreachable;
        try out.appendSlice(allocator, head);
        if (op.b) |b| {
            const tail = std.fmt.bufPrint(&buf, ", %{d}", .{b.id}) catch unreachable;
            try out.appendSlice(allocator, tail);
        }
        try out.append(allocator, '\n');
    }
    return out.toOwnedSlice(allocator);
}

/// The `typed` lowering kind of a CFG op tag, or null for a tag that
/// lowers to a direct opcode, a `.compare` rule, or a composite (not
/// part of the typed arithmetic / cast layer). Centralizes the tag →
/// kind mapping for both the expander and the budget.
pub fn typedKindOf(tag: cfg.OpTag) ?llir.TypedKind {
    return switch (llir.lower(tag)) {
        .typed => |k| k,
        else => null,
    };
}

/// Whether `t` is a primitive integer whose ordering immediates
/// zero-extend (`sltiu`/`sgtiu`): the unsigned reps, including `byte`.
fn isUnsignedInteger(t: meta.Type) bool {
    return switch (t) {
        .primitive => |k| k == .uint32 or k == .uint64 or k == .byte,
        else => false,
    };
}

// --- Shared comparison-lowering decisions -----------------------------
//
// The E-type comparison (the value form in `cfg_lower_llir_emit.cmpSel`
// / `immOf`) and the fused B-type branch (`cfg_lower_llir_control`
// `fusedBranchOperands` / `immBranchOf`) make the same four decisions
// about a comparison relation: how to swap its operands, how to move a
// constant to the right operand, how to fold a non-strict ordering by
// ±1, and how to recognize a non-strict integer ordering. These helpers
// own those decisions so the two layers cannot drift.

/// Whether `t` is an integer primitive — the reps the ordering and
/// equality immediates cover. Shared with `cfg_lower_llir`'s
/// `Builder.isInteger` and the control pass's fused-branch recognition.
pub fn isIntegerType(t: meta.Type) bool {
    return switch (t) {
        .primitive => |k| k == .int32 or k == .uint32 or k == .int64 or k == .uint64 or k == .byte,
        else => false,
    };
}

/// The same relation with its operands exchanged (`a < b` ≡ `b > a`): the
/// **swap** that moves a constant from the left operand to the right,
/// where the immediate forms place it, and that the fused branch applies
/// for a non-strict integer ordering. Null for the symmetric `eq`/`ne`
/// and the non-comparison tags (the caller keeps the operand order).
/// Shared by the E-type comparison emitter (`cmpSel`), the fused branch
/// (`fusedBranchOperands` / `immBranchOf`), and the const+op fusion pass.
pub fn swapRel(tag: cfg.OpTag) ?cfg.OpTag {
    return switch (tag) {
        .lt => .gt,
        .gt => .lt,
        .le => .ge,
        .ge => .le,
        else => null,
    };
}

/// Whether the relation is a non-strict integer ordering (`le`/`ge`).
/// The fused-branch recognition uses it to select the real non-strict
/// B-type `ble`/`bleu`; the E-type register comparison instead resolves
/// the single `sle`/`sleu` opcode through `llir.cmpOpcode`. Shared by
/// both layers.
pub fn isNonStrictInt(tag: cfg.OpTag, t: meta.Type) bool {
    return (tag == .le or tag == .ge) and isIntegerType(t);
}

/// A relation folded to its strict predecessor on an adjusted constant.
pub const StrictFold = struct { tag: cfg.OpTag, cv: meta.ConstValue };

/// Fold a non-strict ordering to its strict predecessor with the constant
/// adjusted by ±1 at compile time (`a <= k` ≡ `a < k+1`, `a >= k` ≡
/// `a > k-1`). This is the only place the **±1** appears — the register
/// form selects the single `sle`/`sleu` opcode instead. Null at the `i64`
/// extremes (the ±1 would overflow) and for a non-integer constant.
/// Shared by the E-type immediate (`immOf`) and the fused B-type
/// immediate branch (`cfg_lower_llir_control.immBranchOf`).
pub fn strictFold(tag: cfg.OpTag, cv: meta.ConstValue) ?StrictFold {
    return switch (tag) {
        .le => switch (cv) {
            .int => |i| if (i == std.math.maxInt(i64)) null else .{ .tag = .lt, .cv = .{ .int = i + 1 } },
            else => null,
        },
        .ge => switch (cv) {
            .int => |i| if (i == std.math.minInt(i64)) null else .{ .tag = .gt, .cv = .{ .int = i - 1 } },
            else => null,
        },
        else => .{ .tag = tag, .cv = cv },
    };
}

/// The fused immediate for a numeric constant at operand type `t` for
/// the CFG binary `tag`, or null when the constant does not fit the 7-bit
/// immediate window or the type has no immediate form. Keyed by the CFG
/// tag because the comparison layer has no `TypedKind` of its own.
/// A non-strict `le`/`ge` folds to its strict predecessor through the
/// shared `strictFold` (`a >= k` ≡ `a > k-1`, `a <= k` ≡ `a < k+1`) —
/// the register comparison selects the single `sle`/`sleu` instead. The fold
/// is guarded at the `i64` extremes (inside `strictFold`) and, for `ge`,
/// on an unsigned operand with `k <= 0` (where `a >= k` is vacuously true
/// and `k-1` would underflow the zero-extended ordering window). The
/// remaining comparison tags and the arithmetic/bitwise/shift tags share
/// the signed window `[-64, 63]` (signed arithmetic, ordering, and
/// `seqi`/`snei`, whose 7-bit field sign-extends) or the zero-extended
/// window `[0, 127]` (unsigned ordering, rep-carrying unsigned
/// arithmetic, and the shift/mask forms); floats never fuse.
pub fn immOf(cv: meta.ConstValue, tag: cfg.OpTag, t: meta.Type) ?u8 {
    // The non-strict `le`/`ge` fold to their strict predecessor on the
    // ±1-adjusted constant (`strictFold`) — the only place the ±1
    // appears; the register form selects the single `sle`/`sleu` instead. An
    // unsigned `a >= k` with `k <= 0` is vacuously true and `k-1` would
    // underflow the zero-extended ordering window, so it is rejected
    // before the fold; the i64 extremes are guarded inside `strictFold`
    // and the rest of the window (`k+1`/`k-1` out of `[0, 127]`) simply
    // fails to fuse.
    if (tag == .ge and isUnsignedInteger(t)) switch (cv) {
        .int => |i| if (i <= 0) return null,
        else => {},
    };
    const folded = strictFold(tag, cv) orelse return null;
    const ftag = folded.tag;
    return switch (folded.cv) {
        .int => |i| switch (t) {
            .primitive => |k| switch (k) {
                .int32, .int64 => blk: {
                    if (ftag == .shl or ftag == .shr or ftag == .bitand or ftag == .bitor or ftag == .bitxor) {
                        if (i < 0 or i > 127) break :blk null;
                        break :blk @intCast(i);
                    }
                    if (i < -64 or i > 63) break :blk null;
                    break :blk @intCast(@as(u8, @bitCast(@as(i8, @intCast(i)))) & 0x7f);
                },
                .uint32, .uint64, .byte => blk: {
                    // Equality fuses to `seqi`/`snei`, whose 7-bit field
                    // sign-extends (Instruction Set §4 immediate
                    // comparisons) — so equality uses the signed window
                    // on every integer type. The unsigned ordering
                    // (`sltiu`/`sgtiu`), the rep-carrying arithmetic
                    // immediates, and the mask/shift forms zero-extend
                    // (`[0, 127]`).
                    if (ftag == .eq or ftag == .ne) {
                        if (i < -64 or i > 63) break :blk null;
                        break :blk @intCast(@as(u8, @bitCast(@as(i8, @intCast(i)))) & 0x7f);
                    }
                    if (i < 0 or i > 127) break :blk null;
                    break :blk @intCast(i);
                },
                else => null,
            },
            else => null,
        },
        .float => null,
        else => null,
    };
}

/// The fused shift count on a 32-bit rep: the opcode masks the count at
/// its width (mod 32 at the 32-bit reps, mod 64 otherwise — Instruction
/// Set §4, §10), so the lowering may pre-reduce a fused count and the
/// opcode masks it again.
pub fn shiftImm(op: llir.Opcode, imm: u8) u8 {
    // mod 32 at the 32-bit reps; the 64-bit and non-shift ops pass the
    // count through (the opcode masks mod 64 at decode).
    return switch (op) {
        .shli_i32, .shli_u32, .shri_i32, .shri_u32 => @intCast(imm % 32),
        else => imm,
    };
}

/// A fuse-eligible constant's immediate form: the immediate opcode and the
/// (possibly shift-masked) immediate field.
pub const FusedImm = struct {
    op: llir.Opcode,
    imm: u8,
};

/// The immediate opcode for a CFG binary `tag` at operand type `t`, or
/// null when the op/type has no immediate form. Comparisons select
/// through the tag-keyed `llir.cmpImmOpcode` (they have no `TypedKind`);
/// the arithmetic/bitwise/shift families resolve through the typed
/// kind's immediate form.
fn immOpcodeOf(tag: cfg.OpTag, t: meta.Type) ?llir.Opcode {
    return switch (tag) {
        .eq, .ne, .lt, .le, .gt, .ge => llir.cmpImmOpcode(tag, t),
        else => switch (llir.lower(tag)) {
            .typed => |k| llir.typedOpcodeImm(k, t),
            else => null,
        },
    };
}

/// The fused immediate for a **right** constant operand (`bin.b`) of a
/// CFG binary op, or null when the constant does not qualify (no
/// immediate form for the tag/type, or the value does not fit the 7-bit
/// window). Keyed by the CFG tag: the comparisons have no `TypedKind`,
/// and `lt`/`le` share the `slti`/`sltiu` ordering family while `gt`/`ge`
/// share `sgti`/`sgtiu` (`a <= k` ≡ `slti a, k+1`, `a >= k` ≡
/// `sgti a, k-1`, the constant folded at compile time).
/// Shared by the fusion pass (rewrites the register form to the immediate
/// form and kills the const record).
pub fn fusedImmR(tag: cfg.OpTag, t: meta.Type, cv: meta.ConstValue) ?FusedImm {
    const op = immOpcodeOf(tag, t) orelse return null;
    const raw = immOf(cv, tag, t) orelse return null;
    return .{ .op = op, .imm = shiftImm(op, raw) };
}

/// The constant payload of a value whose defining instruction is a `const_`,
/// or null for every other value.
pub fn constOf(v: *const cfg.Value) ?meta.ConstValue {
    const d = v.def orelse return null;
    return switch (d.op) {
        .const_ => |cv| cv,
        else => null,
    };
}

test "shiftImm pre-reduces a fused count at the 32-bit reps only" {
    // The 32-bit shift-immediate members: mod 32.
    try std.testing.expectEqual(@as(u8, 3), shiftImm(.shli_i32, 35));
    try std.testing.expectEqual(@as(u8, 0), shiftImm(.shri_u32, 32));
    try std.testing.expectEqual(@as(u8, 7), shiftImm(.shri_i32, 7));
    // The 64-bit members: unchanged (the opcode masks mod 64).
    try std.testing.expectEqual(@as(u8, 35), shiftImm(.shli_i64, 35));
    try std.testing.expectEqual(@as(u8, 66), shiftImm(.shri_i64, 66));
    // Register-form shifts and non-shifts: unchanged.
    try std.testing.expectEqual(@as(u8, 40), shiftImm(.shl_i32, 40));
    try std.testing.expectEqual(@as(u8, 5), shiftImm(.addi_i32, 5));
}

test "fusedImmR picks the typed immediate opcode" {
    const ti32 = meta.Type{ .primitive = .int32 };
    const tu32 = meta.Type{ .primitive = .uint32 };

    // Signed: sign-extended window [-64, 63]; unsigned: [0, 127].
    const f1 = fusedImmR(.add, ti32, .{ .int = -1 }).?;
    try std.testing.expectEqual(Opcode.addi_i32, f1.op);
    try std.testing.expectEqual(@as(u8, 0x7f), f1.imm);
    const f2 = fusedImmR(.add, tu32, .{ .int = 127 }).?;
    try std.testing.expectEqual(Opcode.addi_u32, f2.op);
    try std.testing.expectEqual(@as(u8, 127), f2.imm);
    // Out of window: no fusion.
    try std.testing.expectEqual(@as(?FusedImm, null), fusedImmR(.add, ti32, .{ .int = 100 }));
    try std.testing.expectEqual(@as(?FusedImm, null), fusedImmR(.add, tu32, .{ .int = -1 }));
    // No immediate form for min/max/neg or floats.
    try std.testing.expectEqual(@as(?FusedImm, null), fusedImmR(.min, ti32, .{ .int = 1 }));
    try std.testing.expectEqual(@as(?FusedImm, null), fusedImmR(.neg, ti32, .{ .int = 1 }));
}

test "fusedImmR gates equality to the sign-extending seqi/snei window" {
    const ti32 = meta.Type{ .primitive = .int32 };
    const tu32 = meta.Type{ .primitive = .uint32 };
    const tu64 = meta.Type{ .primitive = .uint64 };

    // Equality fuses to seqi/snei, which sign-extend the 7-bit field on
    // every integer type: only [-64, 63] fits, even for unsigned operands.
    const f1 = fusedImmR(.eq, ti32, .{ .int = -1 }).?;
    try std.testing.expectEqual(Opcode.seqi, f1.op);
    try std.testing.expectEqual(@as(u8, 0x7f), f1.imm);
    const f2 = fusedImmR(.eq, tu32, .{ .int = 63 }).?;
    try std.testing.expectEqual(Opcode.seqi, f2.op);
    try std.testing.expectEqual(@as(u8, 63), f2.imm);
    // 100 fits the unsigned arithmetic window but not seqi's — no fusion.
    try std.testing.expectEqual(@as(?FusedImm, null), fusedImmR(.eq, tu32, .{ .int = 100 }));
    try std.testing.expectEqual(@as(?FusedImm, null), fusedImmR(.eq, tu64, .{ .int = 127 }));
    try std.testing.expectEqual(@as(?FusedImm, null), fusedImmR(.ne, tu32, .{ .int = 64 }));
    // The unsigned ordering (sltiu/sgtiu) keeps the [0, 127] window.
    const f3 = fusedImmR(.lt, tu32, .{ .int = 127 }).?;
    try std.testing.expectEqual(Opcode.sltiu, f3.op);
    try std.testing.expectEqual(@as(u8, 127), f3.imm);
}

test "fusedImmR fuses gt/ge to the sgti ordering family" {
    const ti32 = meta.Type{ .primitive = .int32 };
    const tu32 = meta.Type{ .primitive = .uint32 };

    // `a > k` → `sgti a, k`; the signed ordering window is [-64, 63].
    const gt = fusedImmR(.gt, ti32, .{ .int = 5 }).?;
    try std.testing.expectEqual(Opcode.sgti, gt.op);
    try std.testing.expectEqual(@as(u8, 5), gt.imm);
    // `a >= k` → `sgti a, k-1` (the decrement, no operand swap). k = -1
    // becomes -2.
    const ge = fusedImmR(.ge, ti32, .{ .int = -1 }).?;
    try std.testing.expectEqual(Opcode.sgti, ge.op);
    try std.testing.expectEqual(@as(u8, 0x7e), ge.imm); // -2 & 0x7f
    // Unsigned ordering zero-extends: `a > k` → `sgtiu a, k`.
    const gtu = fusedImmR(.gt, tu32, .{ .int = 100 }).?;
    try std.testing.expectEqual(Opcode.sgtiu, gtu.op);
    try std.testing.expectEqual(@as(u8, 100), gtu.imm);
    const geu = fusedImmR(.ge, tu32, .{ .int = 100 }).?;
    try std.testing.expectEqual(Opcode.sgtiu, geu.op);
    try std.testing.expectEqual(@as(u8, 99), geu.imm);
    // The k-1 underflow at the signed minimum never fuses.
    try std.testing.expectEqual(@as(?FusedImm, null), fusedImmR(.ge, ti32, .{ .int = std.math.minInt(i64) }));
    // Out-of-window constants do not fuse.
    try std.testing.expectEqual(@as(?FusedImm, null), fusedImmR(.gt, ti32, .{ .int = 64 }));
    try std.testing.expectEqual(@as(?FusedImm, null), fusedImmR(.gt, tu32, .{ .int = -1 }));
    // No float immediate ordering forms.
    try std.testing.expectEqual(@as(?FusedImm, null), fusedImmR(.gt, .{ .primitive = .float32 }, .{ .int = 1 }));
    try std.testing.expectEqual(@as(?FusedImm, null), fusedImmR(.ge, .{ .primitive = .float64 }, .{ .int = 1 }));
}

test "fusedImmR le/ge guard: constant-fold boundaries and windows" {
    const ti32 = meta.Type{ .primitive = .int32 };
    const tu32 = meta.Type{ .primitive = .uint32 };
    const tu64 = meta.Type{ .primitive = .uint64 };
    const tbyte = meta.Type{ .primitive = .byte };
    const tf32 = meta.Type{ .primitive = .float32 };

    // Unsigned `a >= k`: `k <= 0` is vacuously true and `k-1` would
    // underflow the zero-extended window — the explicit guard rejects it
    // on every unsigned rep.
    try std.testing.expectEqual(@as(?FusedImm, null), fusedImmR(.ge, tu32, .{ .int = 0 }));
    try std.testing.expectEqual(@as(?FusedImm, null), fusedImmR(.ge, tbyte, .{ .int = 0 }));
    try std.testing.expectEqual(@as(?FusedImm, null), fusedImmR(.ge, tu64, .{ .int = 0 }));
    // Positive unsigned `ge` still decrements into `[0, 127]`; `k` itself
    // may sit one past the window (k = 128 → imm 127).
    const geu1 = fusedImmR(.ge, tu32, .{ .int = 1 }).?;
    try std.testing.expectEqual(Opcode.sgtiu, geu1.op);
    try std.testing.expectEqual(@as(u8, 0), geu1.imm);
    const geu127 = fusedImmR(.ge, tu32, .{ .int = 127 }).?;
    try std.testing.expectEqual(Opcode.sgtiu, geu127.op);
    try std.testing.expectEqual(@as(u8, 0x7e), geu127.imm); // 126
    const geu128 = fusedImmR(.ge, tu32, .{ .int = 128 }).?;
    try std.testing.expectEqual(Opcode.sgtiu, geu128.op);
    try std.testing.expectEqual(@as(u8, 0x7f), geu128.imm); // 127
    try std.testing.expectEqual(@as(?FusedImm, null), fusedImmR(.ge, tu32, .{ .int = 129 }));

    // The unsigned guard is `ge`-only: `a > 0` still fuses.
    const gtu0 = fusedImmR(.gt, tu32, .{ .int = 0 }).?;
    try std.testing.expectEqual(Opcode.sgtiu, gtu0.op);
    try std.testing.expectEqual(@as(u8, 0), gtu0.imm);
    const gtu127 = fusedImmR(.gt, tu32, .{ .int = 127 }).?;
    try std.testing.expectEqual(Opcode.sgtiu, gtu127.op);
    try std.testing.expectEqual(@as(u8, 0x7f), gtu127.imm); // 127
    try std.testing.expectEqual(@as(?FusedImm, null), fusedImmR(.gt, tu32, .{ .int = 128 }));

    // Signed `a >= k` keeps decrementing: imm is `(k-1) & 0x7f`, valid
    // for `k-1 ∈ [-64, 63]`, i.e. `k ∈ [-63, 64]`.
    const ge0 = fusedImmR(.ge, ti32, .{ .int = 0 }).?;
    try std.testing.expectEqual(Opcode.sgti, ge0.op);
    try std.testing.expectEqual(@as(u8, 0x7f), ge0.imm); // -1 & 0x7f
    const gem63 = fusedImmR(.ge, ti32, .{ .int = -63 }).?;
    try std.testing.expectEqual(Opcode.sgti, gem63.op);
    try std.testing.expectEqual(@as(u8, 0x40), gem63.imm); // -64 & 0x7f
    try std.testing.expectEqual(@as(?FusedImm, null), fusedImmR(.ge, ti32, .{ .int = -64 }));
    const ge63 = fusedImmR(.ge, ti32, .{ .int = 63 }).?;
    try std.testing.expectEqual(Opcode.sgti, ge63.op);
    try std.testing.expectEqual(@as(u8, 0x3e), ge63.imm); // 62
    const ge64 = fusedImmR(.ge, ti32, .{ .int = 64 }).?;
    try std.testing.expectEqual(Opcode.sgti, ge64.op);
    try std.testing.expectEqual(@as(u8, 0x3f), ge64.imm); // 63: k-1 still in window
    try std.testing.expectEqual(@as(?FusedImm, null), fusedImmR(.ge, ti32, .{ .int = 65 }));
    try std.testing.expectEqual(@as(?FusedImm, null), fusedImmR(.ge, ti32, .{ .int = std.math.minInt(i64) }));

    // Signed `a > k` is the un-decremented window `[-64, 63]`.
    const gt63 = fusedImmR(.gt, ti32, .{ .int = 63 }).?;
    try std.testing.expectEqual(Opcode.sgti, gt63.op);
    try std.testing.expectEqual(@as(u8, 0x3f), gt63.imm); // 63
    try std.testing.expectEqual(@as(?FusedImm, null), fusedImmR(.gt, ti32, .{ .int = 64 }));
    const gtm64 = fusedImmR(.gt, ti32, .{ .int = -64 }).?;
    try std.testing.expectEqual(Opcode.sgti, gtm64.op);
    try std.testing.expectEqual(@as(u8, 0x40), gtm64.imm); // -64 & 0x7f
    try std.testing.expectEqual(@as(?FusedImm, null), fusedImmR(.gt, ti32, .{ .int = -65 }));

    // `le` folds to `slti` with a compile-time `k+1`: `a <= k` ≡
    // `a < k+1`. Signed `k+1 ∈ [-64, 63]`, i.e. `k ∈ [-65, 62]`; the
    // unsigned `sltiu` window zero-extends (`k ∈ [-1, 126]`). Floats
    // never fuse.
    const le0 = fusedImmR(.le, ti32, .{ .int = 0 }).?;
    try std.testing.expectEqual(Opcode.slti, le0.op);
    try std.testing.expectEqual(@as(u8, 1), le0.imm);
    const lem65 = fusedImmR(.le, ti32, .{ .int = -65 }).?;
    try std.testing.expectEqual(Opcode.slti, lem65.op);
    try std.testing.expectEqual(@as(u8, 0x40), lem65.imm); // -64 & 0x7f
    const le62 = fusedImmR(.le, ti32, .{ .int = 62 }).?;
    try std.testing.expectEqual(Opcode.slti, le62.op);
    try std.testing.expectEqual(@as(u8, 63), le62.imm);
    try std.testing.expectEqual(@as(?FusedImm, null), fusedImmR(.le, ti32, .{ .int = -66 }));
    try std.testing.expectEqual(@as(?FusedImm, null), fusedImmR(.le, ti32, .{ .int = 63 }));
    // The k+1 overflow at the signed maximum never fuses.
    try std.testing.expectEqual(@as(?FusedImm, null), fusedImmR(.le, ti32, .{ .int = std.math.maxInt(i64) }));
    const leu126 = fusedImmR(.le, tu32, .{ .int = 126 }).?;
    try std.testing.expectEqual(Opcode.sltiu, leu126.op);
    try std.testing.expectEqual(@as(u8, 127), leu126.imm);
    try std.testing.expectEqual(@as(?FusedImm, null), fusedImmR(.le, tu32, .{ .int = 127 }));
    // Unsigned `a <= -1` is `a < 0` — fuses to `sltiu a, 0` (false).
    const leuneg = fusedImmR(.le, tu32, .{ .int = -1 }).?;
    try std.testing.expectEqual(Opcode.sltiu, leuneg.op);
    try std.testing.expectEqual(@as(u8, 0), leuneg.imm);
    try std.testing.expectEqual(@as(?FusedImm, null), fusedImmR(.le, tu32, .{ .int = -2 }));
    // Floats never fuse.
    try std.testing.expectEqual(@as(?FusedImm, null), fusedImmR(.ge, tf32, .{ .int = 1 }));
    try std.testing.expectEqual(@as(?FusedImm, null), fusedImmR(.gt, tf32, .{ .int = 1 }));
    try std.testing.expectEqual(@as(?FusedImm, null), fusedImmR(.le, tf32, .{ .int = 1 }));
}

const Opcode = llir.Opcode;

test "swapRel exchanges a relation's operands; symmetric relations do not swap" {
    // `a < b` ≡ `b > a`, `a <= b` ≡ `b >= a`, and their mirrors.
    try std.testing.expectEqual(@as(?cfg.OpTag, .gt), swapRel(.lt));
    try std.testing.expectEqual(@as(?cfg.OpTag, .lt), swapRel(.gt));
    try std.testing.expectEqual(@as(?cfg.OpTag, .ge), swapRel(.le));
    try std.testing.expectEqual(@as(?cfg.OpTag, .le), swapRel(.ge));
    // Equality is symmetric; the arithmetic/bitwise tags are not relations.
    try std.testing.expectEqual(@as(?cfg.OpTag, null), swapRel(.eq));
    try std.testing.expectEqual(@as(?cfg.OpTag, null), swapRel(.ne));
    try std.testing.expectEqual(@as(?cfg.OpTag, null), swapRel(.add));
    // The swap is an involution on the ordering relations.
    for ([_]cfg.OpTag{ .lt, .gt, .le, .ge }) |tag| {
        try std.testing.expectEqual(tag, swapRel(swapRel(tag).?).?);
    }
}

test "strictFold adjusts the non-strict ordering constant by ±1" {
    // `a <= k` ≡ `a < k+1`, `a >= k` ≡ `a > k-1`.
    const le = strictFold(.le, .{ .int = 5 }).?;
    try std.testing.expectEqual(cfg.OpTag.lt, le.tag);
    try std.testing.expectEqual(@as(i64, 6), le.cv.int);
    const ge = strictFold(.ge, .{ .int = 5 }).?;
    try std.testing.expectEqual(cfg.OpTag.gt, ge.tag);
    try std.testing.expectEqual(@as(i64, 4), ge.cv.int);
    // A strict relation (or a non-ordering tag) passes through unchanged.
    const lt = strictFold(.lt, .{ .int = 5 }).?;
    try std.testing.expectEqual(cfg.OpTag.lt, lt.tag);
    try std.testing.expectEqual(@as(i64, 5), lt.cv.int);
    const eq = strictFold(.eq, .{ .int = -1 }).?;
    try std.testing.expectEqual(cfg.OpTag.eq, eq.tag);
    try std.testing.expectEqual(@as(i64, -1), eq.cv.int);
    // The i64 extremes cannot be adjusted; a non-integer constant never folds.
    try std.testing.expectEqual(@as(?StrictFold, null), strictFold(.le, .{ .int = std.math.maxInt(i64) }));
    try std.testing.expectEqual(@as(?StrictFold, null), strictFold(.ge, .{ .int = std.math.minInt(i64) }));
    try std.testing.expectEqual(@as(?StrictFold, null), strictFold(.le, .{ .float = 1.0 }));
    try std.testing.expectEqual(@as(?StrictFold, null), strictFold(.ge, .{ .float = 1.0 }));
    // Identity on a strict tag: even a float payload passes through the fold
    // (the window, not the fold, rejects it).
    const f = strictFold(.lt, .{ .float = 1.0 }).?;
    try std.testing.expectEqual(cfg.OpTag.lt, f.tag);
}

test "isNonStrictInt recognizes the integer le/ge" {
    const ti32 = meta.Type{ .primitive = .int32 };
    const tu32 = meta.Type{ .primitive = .uint32 };
    const tf32 = meta.Type{ .primitive = .float32 };
    const tbool = meta.Type{ .primitive = .bool };
    // Only the integer `le`/`ge` are non-strict integer orderings; float
    // `le`/`ge` use the dedicated `sle.f32`/`sle.f64`.
    try std.testing.expect(isNonStrictInt(.le, ti32));
    try std.testing.expect(isNonStrictInt(.ge, tu32));
    try std.testing.expect(!isNonStrictInt(.lt, ti32));
    try std.testing.expect(!isNonStrictInt(.gt, ti32));
    try std.testing.expect(!isNonStrictInt(.le, tf32));
    try std.testing.expect(!isNonStrictInt(.ge, tf32));
    try std.testing.expect(!isNonStrictInt(.le, tbool));
    // The shared predicate matches the `byte` unsigned family.
    try std.testing.expect(isIntegerType(.{ .primitive = .byte }));
    try std.testing.expect(isIntegerType(ti32));
    try std.testing.expect(!isIntegerType(tf32));
    try std.testing.expect(!isIntegerType(.{ .module = {} }));
}

test "typedOps lists one atomic node per arithmetic instruction" {
    // Covered at the pipeline level (frontend_llir_typed_tests.zig);
    // the helpers above are the unit-testable surface.
}
