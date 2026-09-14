// seg — the opt-in SEG rewrite families (hir.md §11) reachable from
// source, none of which any other corpus probe reaches: known-variant
// `match` reduction (single / multi payload / nullary / nested payload /
// wildcard / catch-all), immediately-invoked lambda β reduction,
// constant folding and integer-algebra identities, constant conditions
// and short-circuit constants, and the cross-full-expression `let` folds
// (hir.md §8.7: a source-level `let` is not an island — its initializer
// opens a nested FE — so its dead / forwarding / atom-copy rules are
// admitted by their boundary contracts instead). `main` prints every
// result so the SEG on/off differential compares observable output
// instead of two empty runs.

const builtin = import("builtin");

union Value {
    number(int32), empty
}

union Flag {
    on, off
}

union Two {
    pair(int32, int32), none
}

struct Point {
    x: int32;
    y: int32;
}

union Shape {
    point(Point), empty
}

fn known_single(x: int32) -> int32 {
    match (Value::number(x)) {
        Value::number(n) => n + 1,
        Value::empty => 0,
    }
}

fn known_nullary() -> int32 {
    match (Flag::off) {
        Flag::on => 1,
        Flag::off => 2,
    }
}

fn known_multi(x: int32, y: int32) -> int32 {
    match (Two::pair(x, y)) {
        Two::pair(a, b) => a - b,
        Two::none => 0,
    }
}

fn known_nested() -> int32 {
    match (Shape::point(Point { x: 1, y: 2 })) {
        Shape::point(Point { x, y }) => x + y,
        Shape::empty => 0,
    }
}

fn known_wildcard(x: int32) -> int32 {
    match (Value::number(x)) {
        Value::number(_) => 7,
        Value::empty => 0,
    }
}

fn known_catchall(x: int32) -> int32 {
    match (Value::number(x)) {
        v => 9,
    }
}

fn identity(x: int32) -> int32 {
    x
}

// An immediately-invoked lambda: SEG's β rule binds the argument and
// inlines the body without duplicating the argument's evaluation.
fn beta(value: int32) -> int32 {
    (fn(a: int32) -> int32 { a + a })(identity(value))
}

fn fold(a: int32) -> int32 {
    (a * 1) + (2 + 3)
}

fn algebra(x: int32) -> int32 {
    (x + 0) + (x * 1)
}

fn constant_if() -> int32 {
    let x = if (1 < 2) { 10 } else { 20 };
    x
}

fn constant_logic() -> bool {
    let x = true or false;
    x
}

// The cross-FE `let` folds (hir.md §8.7). A source-level initializer
// opens its own full expression, so the `let` is not an island member and
// each fold is admitted by its boundary contract instead of by island
// membership: `unused_let`'s discardable initializer is dropped,
// `forward_once`'s island-member initializer moves to its single use, and
// `atom_twice`'s trivial atom is copied to both uses.
fn unused_let(x: int32) -> int32 {
    let unused: int32 = identity(x);
    x
}

fn forward_once(x: int32) -> int32 {
    let y = x + 1;
    y * 2
}

fn atom_twice(x: int32) -> int32 {
    let y = x;
    y + y
}

// The refused shapes, each keeping its `let`. `borrowed_kept`'s atom fails
// `isDuplicable`'s ownership gate, `trapping_kept`'s initializer may trap,
// `observable_kept`'s call prints (so it is neither an island member nor
// effect-free), `coerced_kept`'s binder type (`any`) is the implicit
// coercion rather than the initializer's node type (`int32`), and
// `unique_kept`'s constructor result is Unique — neither an island member
// nor Copy, so the drop hook still runs.
fn borrowed_kept(borrow x: int32) -> int32 {
    let y = x;
    y + y
}

fn trapping_kept(x: int32) -> int32 {
    let y = 10 / x;
    y + 1
}

fn shout(x: int32) -> int32 {
    builtin.print("shout");
    x
}

fn observable_kept(x: int32) -> int32 {
    let y = shout(x);
    y + 1
}

fn coerced_kept(x: int32) -> int32 {
    let dynamic: any = x;
    dynamic as int32
}

struct Token {
    id: int32;
    drop(t) { builtin.print("token"); }
}

fn make_token(id: int32) -> Token { Token { id: id } }

fn unique_kept(x: int32) -> int32 {
    let t = make_token(x);
    t.id
}

fn logic_result() -> int32 {
    if (constant_logic()) {
        1
    } else {
        0
    }
}

fn main() -> void {
    builtin.print(builtin.str(known_single(4)));
    builtin.print(builtin.str(known_nullary()));
    builtin.print(builtin.str(known_multi(9, 4)));
    builtin.print(builtin.str(known_nested()));
    builtin.print(builtin.str(known_wildcard(3)));
    builtin.print(builtin.str(known_catchall(3)));
    builtin.print(builtin.str(beta(21)));
    builtin.print(builtin.str(fold(5)));
    builtin.print(builtin.str(algebra(5)));
    builtin.print(builtin.str(constant_if()));
    builtin.print(builtin.str(logic_result()));
    builtin.print(builtin.str(unused_let(6)));
    builtin.print(builtin.str(forward_once(7)));
    builtin.print(builtin.str(atom_twice(8)));
    builtin.print(builtin.str(borrowed_kept(9)));
    builtin.print(builtin.str(trapping_kept(10)));
    builtin.print(builtin.str(observable_kept(11)));
    builtin.print(builtin.str(coerced_kept(12)));
    builtin.print(builtin.str(unique_kept(13)));
}
