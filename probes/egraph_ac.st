// egraph_ac — the full integer associativity + commutativity search
// (hir.md §8.2, the `egraph_ac` toggle). `(a + b) + c` and `a + (b + c)`
// are structurally different, so hash-consing and the in-place
// commutativity swap alone never put them in one class: only the AC
// search's flatten → stable-sort → left-deep regroup does. Both
// bracketings land in one e-class and extraction emits the single
// canonical (AC-root) left-deep chain, so the `==` compares that value
// with itself — which every associative regrouping preserves, so the
// property is a truth the *unsound* reassociation of a non-associative op
// would break, but which the sound search always upholds.

const builtin = import("builtin");

// The two bracketings of the same three operands. Neither hash-consing nor
// the `eq` in-place swap can merge `(a + b) + c` with `a + (b + c)`; only
// the regroup does. The two forms tie on cost, so extraction's `ac_root`
// tie-break picks the canonical left-deep chain and the left operand of the
// `==` is the very node the right operand extracts to.
//
// The regroup is value-preserving, so the `==` holds with AC on and off;
// `main` prints `1` either way and the on/off runtime output is
// *intentionally identical*. The real assertion lives in the AIR
// (`src/hir_seg_tests.zig`): with `egraph_ac` on the two `==` operands
// extract to the same node (`eq %t, %t`), with it off they stay the two
// source bracketings. Do not read the printed value as an AC differential.
fn ac_brackets(a: int32, b: int32, c: int32) -> int32 {
    if (((a + b) + c) == (a + (b + c))) { 1 } else { 0 }
}

fn main() -> void {
    builtin.print(builtin.str(ac_brackets(2, 3, 5)));
}
