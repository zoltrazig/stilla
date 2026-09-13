// cse — CSE-style sharing (hir.md §8.3): within one island, two
// α-equivalent and `isDuplicable` operands of one `strict_ltr`,
// region-free node are computed once and read from a synthesized `let`.
// `main` prints every result so the SEG on/off differential compares
// observable output instead of two empty runs.

const builtin = import("builtin");

struct Point {
    x: int32;
    y: int32;
}

// Two identical `mul` island members share one evaluation.
fn shared_mul(x: int32, y: int32) -> int32 { (x * y) + (x * y) }

// Two identical field reads share the projection.
fn shared_field(p: Point) -> int32 { p.x + p.x }

// The shared operand is itself a non-trivial pure subtree.
fn shared_nested(a: int32, b: int32) -> int32 { (a + b) * (a + b) }

struct Token {
    value: int32;
    drop(token) {}
}

struct Two {
    a: Token;
    b: Token;
}

// Refused: the two `Token` constructors are Unique and consumed by the
// aggregate binding, so neither is an island member / duplicable; they
// stay separate.
fn unique_no_share(v: int32) -> int32 {
    let two = Two { a: Token { value: v }, b: Token { value: v } };
    two.a.value + two.b.value
}

fn main() -> void {
    builtin.print(builtin.str(shared_mul(6, 7)));
    builtin.print(builtin.str(shared_field(Point { x: 11, y: 22 })));
    builtin.print(builtin.str(shared_nested(3, 4)));
    builtin.print(builtin.str(unique_no_share(5)));
}
