// fold — lists and the `iter` combinators (Core §11, StdLib §7).
//
// Stilla has no loop construct; `iter` is the standard recursion
// library. `fold` threads a moved accumulator through a borrowed list;
// the step function takes `move S` and `borrow T` and returns the next
// accumulator. The context-threading `*_with` variants exist for
// closures-free composition (Core §13.5), but plain `fold`/`each` cover
// most cases. List literals, list patterns, and element reads via
// non-consuming matching are exercised too — there is no indexed read
// (`list.get` does not exist; Core §11.5).

const builtin = import("builtin");
const iter = import("iter");
const lists = import("list");
using builtin.Option;

/// Count a list with explicit recursion over the [head, ..tail] pattern.
fn count_list(xs: list[int32]) -> int32 {
    match (xs) {
        [] => 0,
        [_, ..tail] => 1 + count_list(tail),
    }
}

fn main() -> void {
    // `list.range` is inclusive: [0, 10] → 11 elements.
    let xs = lists.range(0, 10);
    builtin.assert(lists.len(xs) == 11, "range length");
    // Element reads happen by non-consuming matching: `[h, ..t]` reads
    // the head element by value (a *Copy* element) or as a borrowed view
    // (a *Unique* element) — Core §11.5.
    builtin.assert(match (xs) { [h, ..t] => h, [] => -1 } == 0, "head element");

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

    // The `list` module (StdLib §8): reads and derived operations.
    // `list` is the type keyword, so the module is bound under `lists`.
    let eq = fn(borrow a: int32, borrow b: int32) -> bool { a == b };
    builtin.assert(!lists.is_empty(xs), "is_empty");
    builtin.assert(lists.contains(xs, 5, eq), "contains");
    builtin.assert(!lists.contains(xs, 42, eq), "contains miss");
    builtin.assert(lists.count(xs, 10, eq) == 1, "count");
    builtin.assert(lists.count(xs, 42, eq) == 0, "count miss");
    match (lists.index_of(xs, 7, eq)) {
        Option::Some(i) => builtin.assert(i == 7, "index_of"),
        Option::None => builtin.assert(false, "index_of found"),
    };
    match (lists.index_of(xs, 42, eq)) {
        Option::Some(_) => builtin.assert(false, "index_of miss"),
        Option::None => (),
    };
    match (lists.head([1, 2, 3])) {
        Option::Some(h) => builtin.assert(h == 1, "head"),
        Option::None => builtin.assert(false, "head found"),
    };
}
