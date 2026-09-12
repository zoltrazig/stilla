// unused — computations and projections whose results are never consumed.
// Exercises dead-instruction elimination (side-effect-free, non-consuming,
// non-trapping ops only) and dead-let simplification: the unused arithmetic,
// shifts, masks, and field loads have no uses but must be kept if they can
// trap or consume.

struct Pair {
    left: int32;
    right: int32;
}

fn dead_math(x: int32) -> int32 {
    let a = x + 1;
    let b = x * 3;
    let c = (x << 2) | (x >> 1);
    let d = x & 255;
    a
}

fn dead_field(pair: Pair) -> int32 {
    let _ = pair.right;
    pair.left
}

fn dead_cond(flag: bool) -> int32 {
    let _ = if (flag) { 1 } else { 2 };
    0
}

fn main() -> void {
    let _ = dead_math(7);
    let _ = dead_field(Pair { left: 1, right: 2 });
    let _ = dead_cond(true);
}
