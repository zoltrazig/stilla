//! Shared value predicates for the LLIR lowering passes — the
//! allocation scan and the fusion peephole both key on these, so they
//! live outside any single pass (neither pass imports the other).
const std = @import("std");
const cfg = @import("stilla").cfg;

/// True when the value is defined by a `mul` instruction (a candidate
/// product for the multiply-accumulate fusion).
pub fn isMulResult(v: *const cfg.Value) bool {
    const d = v.def orelse return false;
    return std.meta.activeTag(d.op) == .mul;
}

/// True when `bin` is a multiply-accumulate shape: one operand is a
/// `mul` result and the other is the accumulator. The integer `add`
/// commutes, so the product may be either operand; the f32 forms never
/// reorder. The caller stamps the exact operand roles and the
/// single-use / adjacency preconditions.
pub fn isMaddAccumulator(bin: cfg.Bin) bool {
    return isMulResult(bin.b) or isMulResult(bin.a);
}

/// True when `bin` is a multiply-subtract shape: the second operand is
/// a `mul` result (`dst = dst - b*c`) and the first is the accumulator.
/// Subtraction does not commute, so a `sub` whose first operand is the
/// product (`b*c - a`) is not an msub shape.
pub fn isMsubAccumulator(bin: cfg.Bin) bool {
    return isMulResult(bin.b);
}

/// The coarse shape test shared by allocation and fusion: true when
/// `op` defines the accumulator of a fused multiply-accumulate or
/// multiply-subtract. Both passes must agree on which result cells may
/// be coalesced with the accumulator, so this delegates to the
/// per-operator shape tests above.
pub fn isFmaAccumulator(op: cfg.Op) bool {
    return switch (op) {
        .add => |bin| isMaddAccumulator(bin),
        .sub => |bin| isMsubAccumulator(bin),
        else => false,
    };
}

/// Whether the value's defining op reads all inputs before
/// writing its single destination — permitted for in-place slot
/// assignment (the def instruction is the occupant's last use, so it
/// reads the slot before overwriting it). Multi-dst ops are
/// conservatively forbidden because their additional results might
/// interfere with the occupant.
pub fn canInPlace(v: *const cfg.Value) bool {
    const d = v.def orelse return false;
    return switch (d.op) {
        .add, .sub, .mul, .div, .rem, .shl, .shr, .bitand, .bitor, .bitxor, .eq, .ne, .lt, .le, .gt, .ge, .const_, .copy, .move_ => true,
        else => false,
    };
}
