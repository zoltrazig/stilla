// egraph — the slotted e-graph arena (hir.md §8.2). The union rules
// (constant folding, integer algebra, aggregate projection) are rewrite
// rules over an e-class table plus union-find, so two operands that are
// never syntactically equal can still end up in one class: `encode` →
// bounded saturation → extraction shares what the *rules* made equal, not
// just what the source wrote twice. `main` prints every result so the SEG
// on/off differential compares observable output instead of two empty
// runs.

const builtin = import("builtin");

struct Pair {
    head: int32;
    tail: int32;
}

// The projection rule is an in-graph union: the read's class becomes the
// projected operand's class, so the constructor and the read disappear
// entirely — and the projected operand is itself reached through a rule
// (`x * 1 → x`), which only the arena's saturation can see.
fn projected_merged(a: int32, b: int32) -> int32 {
    Pair { head: (a * b) * 1, tail: a + b }.head
}

// The right `mul` folds to its left operand (`x * 1 → x`), so congruence
// merges the two `mul` classes and extraction materializes the merged
// class as one evaluation at the `add`: `let t = a * b { t + t }`.
fn merged_after_rule(a: int32, b: int32) -> int32 {
    (a * b) + ((a * b) * 1)
}

// Congruence reaches through depth: each side's inner product merges into
// one class first, so the two outer `mul`s are `mul(%t, c)` for the same
// class `%t` and collapse to a single evaluation.
fn deep_merge(a: int32, b: int32, c: int32) -> int32 {
    ((a * b) * c) + (((a * b) + 0) * c)
}

// The island is the `let`'s region body `(y * 1) + (y * 1)` — the
// initializer opens its own full expression, so `y` is bound *outside*
// the island (hir.md §8.7). Both folds land in one class, which is a
// trivial atom, so extraction duplicates it instead of materializing a
// `let`, and each emitted copy still names `y`.
fn outer_binder_dup(a: int32) -> int32 {
    let y = a + 1;
    (y * 1) + (y * 1)
}

// Refused shape: the initializer may trap, so no node inside it is an
// island member (hir.md §8.1 recursive encodability) — the two α-equal
// products there stay distinct even though the rule would merge them.
fn refused_kept(a: int32, b: int32) -> int32 {
    let q = ((a * b) + ((a * b) * 1)) / (a + b);
    q + q
}

fn main() -> void {
    builtin.print(builtin.str(merged_after_rule(3, 4)));
    builtin.print(builtin.str(deep_merge(2, 3, 5)));
    builtin.print(builtin.str(outer_binder_dup(7)));
    builtin.print(builtin.str(refused_kept(4, 2)));
    builtin.print(builtin.str(projected_merged(6, 5)));
}
