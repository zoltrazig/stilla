// tuple_list_encoding — SEG's `tuple_make` / `list_make` island encoding
// (hir.md §8.3). Landing the `construct` encoding puts both aggregates in
// the CSE sharing candidate set, so two α-equal duplicable elements inside
// one literal evaluate once and feed a synthesized `let`. The tuple / list
// *projection* rules are IR-level only — Stilla has no element-read suffix
// (Core Expression Binding Power Table: "there is no index-read suffix"), so
// elements are read by destructuring patterns, never `field_get`. `main`
// prints every result so the SEG on/off differential compares observable
// output.

const builtin = import("builtin");

// Both `mul` operands are α-equal and duplicable: the tuple_make is now an
// island, so ruleCse materializes one `mul` into a `let` and rewrites the
// other into a binder read.
fn tuple_shared(x: int32, y: int32) -> int32 {
    let (a, b) = (x * y, x * y);
    a + b
}

// Same sharing through a `list_make` parent.
fn list_shared(x: int32, y: int32) -> int32 {
    let [a, b] = [x * y, x * y];
    a + b
}

// Distinct operands are not α-equal: no sharing, both computations survive.
fn tuple_distinct(x: int32, y: int32) -> int32 {
    let (a, b) = (x * y, x + y);
    a + b
}

fn main() -> void {
    builtin.print(builtin.str(tuple_shared(3, 4)));
    builtin.print(builtin.str(list_shared(3, 4)));
    builtin.print(builtin.str(tuple_distinct(3, 4)));
}
