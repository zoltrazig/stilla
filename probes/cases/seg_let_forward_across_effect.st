// Whole-pipeline AIR fixture for SEG's used-once `let` forwarding
// (hir.md §8.7): the pure initializer `x + 1` is a Copy island member read
// once, so the `let` rule relocates its single evaluation to the use point
// *after* the intervening `print`. With forwarding on the `add` lowers
// after the syscall; with it off the `let` keeps the `add` in the entry
// position, so the emitted AIR differs in evaluation order (not merely in
// text). The source `let` initializer opens its own full expression, so the
// rule is admitted by the boundary contract rather than island membership.
const builtin = import("builtin");

fn f(x: int32) -> int32 {
    let y = x + 1;
    builtin.print("a");
    y * 2
}

fn main() -> void { let _: int32 = f(3); }
