// minmax — tiny pure helpers inlined into a tail-recursive driver.
//
// `min`, `max`, `abs`, and `clamp` are each a few instructions, far
// below the inliner's budget (optimizer.md, Pass 8.0), so every call
// site is replaced by a spliced copy of the callee's body. The driver's
// tail recursion is rewritten to a loop, and the helper copies land
// inside the loop body — several call sites of the same helper, Copy-only
// arguments, and inlining into a TCO loop in one program.

const builtin = import("builtin");

/// min(a, b) = the smaller of a and b.
fn min(a: int32, b: int32) -> int32 {
    if (a < b) { a } else { b }
}

/// max(a, b) = the larger of a and b.
fn max(a: int32, b: int32) -> int32 {
    if (a > b) { a } else { b }
}

/// abs(x) = |x| (negation traps on the minimum int32, Runtime §7.2).
fn abs(x: int32) -> int32 {
    if (x < 0) { -x } else { x }
}

/// clamp(x, lo, hi) = min(max(x, lo), hi).
fn clamp(x: int32, lo: int32, hi: int32) -> int32 {
    max(min(x, hi), lo)
}

/// Walk the range [i, n), clamping a running state: the helpers' inlined
/// copies sit in the TCO loop body. The loop body calls three helpers,
/// pushing its cost past the inline budget so it stays a call in `main`.
fn walk(i: int32, n: int32, state: int32) -> int32 {
    if (i < n) {
        let s = clamp(abs(state) + min(i, 10), -100, 100);
        walk(i + 1, n, s)
    } else {
        state
    }
}

fn main() -> void {
    builtin.assert(min(3, 7) == 3, "min");
    builtin.assert(max(3, 7) == 7, "max");
    builtin.assert(abs(-4) == 4, "abs");
    builtin.assert(walk(0, 100, 0) == 100, "clamped walk");
}
