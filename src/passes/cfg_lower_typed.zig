//! Pass: the typed lowering layer (Layer A of the CFG → LLIR
//! boundary). The emitter reads a value's type only long enough to pick
//! the typed opcode (`add.i32`/`shr.u64`/…) — the opcode carries the
//! full rep, computes at that width, and self-canonicalizes its result
//! cell (Instruction Set §4), so one arithmetic instruction is exactly
//! one record. There is no value-form (top-bits) machinery in v10: the
//! canonical-cell contract is uniform across producers (a typed opcode,
//! a cast, or a `const` canonicalizes), so no canonicalization records
//! exist and nothing needs to track a cell's extension state.
//!
//! What remains here is the typed-op view (the atomic arithmetic /
//! comparison / cast nodes and their printer) and the immediate-fusion
//! helpers the expander-adjacent fusion pass shares.

const std = @import("std");
const cfg = @import("stilla").cfg;
const llir = @import("stilla").llir;
const ast = @import("stilla").ast;

/// A typed lowering op (Layer A): one arithmetic / comparison / cast
/// choice, atomic. `type_` is the operand type; `result_type` is the
/// result type (only meaningful for a cast, where the CFG's
/// `num_cast` target differs from the operand type). `b` is null for
/// the unary arithmetic ops.
pub const TypedOp = struct {
    kind: llir.TypedKind,
    type_: cfg.Type,
    result_type: cfg.Type,
    a: *const cfg.Value,
    b: ?*const cfg.Value,
    result: *const cfg.Value,
};

/// The rep suffix of an arithmetic primitive type, or null for a
/// non-arithmetic type (the typed layer only carries arithmetic ops).
fn repName(t: cfg.Type) ?[]const u8 {
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
        .eq => "eq",
        .ne => "ne",
        .lt => "lt",
        .le => "le",
        .gt => "gt",
        .ge => "ge",
        .neg => "neg",
        .cast => "cvt",
        .abs => "abs",
        .min => "min",
        .max => "max",
        .clz => "clz",
        .popcount => "popcount",
    };
}

/// Build the Layer A typed-op list for one function: the arithmetic,
/// comparison, and cast instructions, each as one atomic typed node.
/// Non-arithmetic instructions are skipped — they are not part of the
/// typed lowering boundary.
pub fn typedOps(allocator: std.mem.Allocator, func: *const cfg.IrFunc) error{OutOfMemory}![]TypedOp {
    var out = std.ArrayList(TypedOp).empty;
    for (func.blocks) |blk| {
        for (blk.instrs) |ins| {
            if (ins.results.len == 0) continue;
            const kind: llir.TypedKind = switch (llir.lower(std.meta.activeTag(ins.op))) {
                .typed => |k| k,
                else => continue, // not an arithmetic/cmp/cast op
            };
            const result = ins.results[0];
            const a: *const cfg.Value = switch (ins.op) {
                .neg, .abs, .clz, .popcount, .num_cast => |v| v,
                .add, .sub, .mul, .div, .rem, .min, .max, .shl, .shr, .bitand, .bitor, .bitxor, .eq, .ne, .lt, .le, .gt, .ge => |bin| bin.a,
                else => unreachable,
            };
            const b: ?*const cfg.Value = switch (ins.op) {
                .neg, .abs, .clz, .popcount, .num_cast => null,
                .add, .sub, .mul, .div, .rem, .min, .max, .shl, .shr, .bitand, .bitor, .bitxor, .eq, .ne, .lt, .le, .gt, .ge => |bin| bin.b,
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
/// line per arithmetic/cmp/cast instruction. The op spelling carries
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
/// lowers to a direct opcode or a composite (not part of the typed
/// arithmetic / comparison / cast layer). Centralizes the tag → kind
/// mapping for both the expander and the budget.
pub fn typedKindOf(tag: cfg.OpTag) ?llir.TypedKind {
    return switch (llir.lower(tag)) {
        .typed => |k| k,
        else => null,
    };
}

/// The fused immediate for a numeric constant at operand type `t`, or null
/// when the constant does not fit the 7-bit immediate window or the type has
/// no immediate form. The typed immediate families sign-extend on the
/// `.i32`/`.i64` members and zero-extend on the `.u32`/`.u64` members;
/// the shift/mask forms always zero-extend; floats never fuse. Integer
/// equality is the exception: its only immediate form is `seqi`/`snei`,
/// which sign-extend the field on every integer type.
pub fn immOf(cv: cfg.ConstValue, kind: llir.TypedKind, t: cfg.Type) ?u8 {
    if (kind == .ge) return switch (cv) {
        .int => |i| if (i == std.math.minInt(i64)) null else immOf(.{ .int = i - 1 }, .gt, t),
        else => null,
    };
    return switch (cv) {
        .int => |i| switch (t) {
            .primitive => |k| switch (k) {
                .int32, .int64 => blk: {
                    if (kind == .shl or kind == .shr or kind == .bitand or kind == .bitor or kind == .bitxor) {
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
                    if (kind == .eq or kind == .ne) {
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

/// The fused immediate for a **right** constant operand (`bin.b`) of a typed
/// arithmetic op, or null when the constant does not qualify (no immediate
/// form for the kind/type, or the value does not fit the 7-bit window).
/// Shared by the fusion pass (rewrites the register form to the immediate
/// form and kills the const record).
pub fn fusedImmR(kind: llir.TypedKind, t: cfg.Type, cv: cfg.ConstValue) ?FusedImm {
    const op = llir.typedOpcodeImm(kind, t) orelse return null;
    const raw = immOf(cv, kind, t) orelse return null;
    return .{ .op = op, .imm = shiftImm(op, raw) };
}

/// The constant payload of a value whose defining instruction is a `const_`,
/// or null for every other value.
pub fn constOf(v: *const cfg.Value) ?cfg.ConstValue {
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
    const ti32 = cfg.Type{ .primitive = .int32 };
    const tu32 = cfg.Type{ .primitive = .uint32 };

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
    const ti32 = cfg.Type{ .primitive = .int32 };
    const tu32 = cfg.Type{ .primitive = .uint32 };
    const tu64 = cfg.Type{ .primitive = .uint64 };

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

const Opcode = llir.Opcode;

test "typedOps lists one atomic node per arithmetic instruction" {
    // Covered at the pipeline level (frontend_llir_typed_tests.zig);
    // the helpers above are the unit-testable surface.
}
