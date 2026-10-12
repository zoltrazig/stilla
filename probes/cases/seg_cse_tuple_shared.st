// Whole-pipeline AIR fixture for SEG's e-graph CSE sharing (hir.md §8.2):
// the two inner tuple literals are α-equal operands of the outer
// `tuple_make`, so congruence merges their classes and extraction
// materializes one evaluation behind a synthesized `let`. The shared class
// is a `construct`, which the HIR lowering's own block-local CSE never
// replays (`cfg_lower_emit`'s candidate set excludes `construct`), so the
// sharing is observable in the emitted AIR — one inner `construct` with
// `egraph_cse` on, two with it off.
fn f(x: int32) -> int32 {
    let ((a, b), (c, d)) = ((x, x), (x, x));
    a + b + c + d
}

fn main() -> void { }
