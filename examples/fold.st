// fold — lists and the `iter` combinators (Core §11, StdLib §7).
//
// Stilla has no loop construct; `iter` is the standard recursion
// library. `fold` threads a moved accumulator through a borrowed list;
// the step function takes `move S` and `borrow T` and returns the next
// accumulator. The context-threading `*_with` variants exist for
// closures-free composition (Core §13.5), but plain `fold`/`each` cover
// most cases. List literals, indexing (`@[...]`), and list patterns are
// exercised too.

const builtin = import("builtin");
const iter = import("iter");

/// Count a list with explicit recursion over the [head, ..tail] pattern.
fn count_list(xs: list[int32]) -> int32 {
    match (xs) {
        [] => 0,
        [_, ..tail] => 1 + count_list(tail),
    }
}

fn main() -> void {
    // `builtin.range` is inclusive: [0, 10] → 11 elements.
    let xs = builtin.range(0, 10);
    builtin.assert(builtin.len(xs) == 11, "range length");
    builtin.assert(xs@[0] == 0 and xs@[10] == 10, "read_index");

    // A fold over int32: sum 0..10.
    let sum = iter.fold[int32, int32](xs, 0,
        fn(move acc: int32, borrow x: int32) -> int32 { acc + x });
    builtin.assert(sum == 55, "fold sum");

    // A fold over a tuple accumulator: count and sum in one pass.
    let (count, total) = iter.fold[int32, tuple[int32, int32]](xs, (0, 0),
        fn(move acc: tuple[int32, int32], borrow x: int32) -> tuple[int32, int32] {
            let (c, s) = acc;
            (c + 1, s + x)
        });
    builtin.assert(count == 11 and total == 55, "tuple accumulator");

    // fold-as-map-into-an-int: running maximum.
    let maxv = iter.fold[int32, int32](xs, 0,
        fn(move acc: int32, borrow x: int32) -> int32 { if (x > acc) { x } else { acc } });
    builtin.assert(maxv == 10, "fold max");

    // `each` visits every element with a borrowed element and no result.
    iter.each[int32](xs, fn(borrow x: int32) -> void {
        builtin.assert(x >= 0, "each element is visited");
    });

    // Recursive list patterns via a user function.
    builtin.assert(count_list(xs) == 11, "count_list");
}
