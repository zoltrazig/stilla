// madd — fused multiply-accumulate and immediate-index list reads.
//
// `x * y + c` lowers to a `mul` followed by an `add`, which the LLIR
// peephole folds into `*_madd` (accumulator read-modify-write:
// `dst = dst + b * c`, two separate IEEE roundings — never a
// fused-rounding FMA); `x * 2 + c` folds to `*_maddi` (the multiplier
// becomes the immediate); a float `c + x * y` keeps the accumulator in
// the first operand position, so the `f32` form fuses without reordering
// the addition; a non-consuming match read at a literal index folds to
// `read_indexi` (the literal index becomes the immediate; the bounds
// check traps as with the register form).

const builtin = import("builtin");
const lists = import("list");

/// int32 FMAC: `x * y + c` — the add commutes (integer add), the
/// accumulator is `c` and the product operand order is preserved.
fn poly(x: int32, y: int32, c: int32) -> int32 {
    x * y + c
}

/// int32 FMAC with a literal multiplier: `*_maddi`, imm = 2.
fn scale(x: int32, c: int32) -> int32 {
    x * 2 + c
}

/// float32 FMAC with the accumulator already first: `c + x * y` fuses
/// without reordering the addition (NaN-payload ordering is preserved).
fn acc(c: float32, x: float32, y: float32) -> float32 {
    c + x * y
}

/// A list read at a literal index via non-consuming matching: the
/// const index folds to `read_indexi`.
fn first(xs: list[int32]) -> int32 {
    match (xs) {
        [] => 0,
        [h, ..t] => h,
    }
}

fn main() -> void {
    builtin.assert(poly(3, 4, 1) == 13, "int32 madd");
    builtin.assert(scale(5, 1) == 11, "int32 maddi");
    builtin.assert(acc(1.0, 2.0, 3.0) == 7.0, "float32 madd");
    builtin.assert(first(lists.range(0, 3)) == 0, "read_indexi");
}
