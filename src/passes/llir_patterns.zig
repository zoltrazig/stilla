//! Shared value predicates for the LLIR lowering passes — the
//! allocation scan and the fusion peephole both key on these, so they
//! live outside any single pass (neither pass imports the other).
const std = @import("std");
const cfg = @import("stilla").cfg;

/// True when the value is defined by a `mul` instruction (a candidate
/// product for the 2.15 multiply-accumulate fusion).
pub fn isMulResult(v: *const cfg.Value) bool {
    const d = v.def orelse return false;
    return std.meta.activeTag(d.op) == .mul;
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
