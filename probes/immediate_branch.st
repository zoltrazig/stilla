// immediate_branch — the imm7 fused integer compare-and-branch family
// (`bgti` / `bgtiu`, `cfg_lower_llir_control.zig`). `a > k` fuses to
// `bgti` when the constant fits the signed window [-64, 63] and to
// `bgtiu` when it fits the unsigned window [0, 127]; a constant on the
// left (`k < a`) swaps to the same family. A constant outside the window
// has no imm7 form and falls back to the register compare with the
// constant materialized. `main` prints one token per shape so the
// consumers / SEG on-off differentials compare observable output
// verbatim.

const builtin = import("builtin");

// --- signed: window [-64, 63] -> `bgti` ---

// `a > 63` (constant on the right) fuses to `bgti`.
fn gt_i32(a: int32) -> str {
    if (a > 63) { ">" } else { "<=" }
}

// `63 < a` (constant on the left) swaps to the same `bgti`.
fn lt_left_i32(a: int32) -> str {
    if (63 < a) { ">" } else { "<=" }
}

// A negative bound still fits (sign-extended): `a > -64` fuses to `bgti`.
fn gt_i32_low(a: int32) -> str {
    if (a > -64) { ">" } else { "<=" }
}

// `64` is one past the signed window, so the constant is materialized and
// the branch takes the register form.
fn gt_i32_oob(a: int32) -> str {
    if (a > 64) { ">" } else { "<=" }
}

// --- unsigned: window [0, 127] -> `bgtiu` ---

// `a > 127` fuses to `bgtiu` (zero-extended).
fn gt_u32(a: uint32) -> str {
    if (a > 127) { ">" } else { "<=" }
}

// `127 < a` (constant on the left) swaps to the same `bgtiu`.
fn lt_left_u32(a: uint32) -> str {
    if (127 < a) { ">" } else { "<=" }
}

// The bottom of the unsigned window still fuses: `a > 0` -> `bgtiu`.
fn gt_u32_low(a: uint32) -> str {
    if (a > 0) { ">" } else { "<=" }
}

// `128` is one past the unsigned window, so the constant is materialized
// and the branch takes the register form.
fn gt_u32_oob(a: uint32) -> str {
    if (a > 128) { ">" } else { "<=" }
}

fn main() -> void {
    builtin.print(gt_i32(100));
    builtin.print(gt_i32(50));
    builtin.print(lt_left_i32(100));
    builtin.print(lt_left_i32(50));
    builtin.print(gt_i32_low(0));
    builtin.print(gt_i32_low(-100));
    builtin.print(gt_i32_oob(100));
    builtin.print(gt_i32_oob(50));
    builtin.print(gt_u32(200));
    builtin.print(gt_u32(100));
    builtin.print(lt_left_u32(200));
    builtin.print(lt_left_u32(100));
    builtin.print(gt_u32_low(5));
    builtin.print(gt_u32_low(0));
    builtin.print(gt_u32_oob(200));
    builtin.print(gt_u32_oob(100));
}
