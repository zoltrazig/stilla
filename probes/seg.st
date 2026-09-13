// seg — the opt-in SEG rewrite families (hir.md §11) reachable from
// source, none of which any other corpus probe reaches: known-variant
// `match` reduction (single / multi payload / nullary / nested payload /
// wildcard / catch-all), immediately-invoked lambda β reduction,
// constant folding and integer-algebra identities, constant conditions
// and short-circuit constants, and the full-expression boundary itself
// (a source-level `let` is not an island: its initializer opens a nested
// FE, so the `if`/`or` folds inside that FE while the enclosing `let`
// survives — hir.md §5.6/§8.7). `main` prints every result so the SEG
// on/off differential compares observable output instead of two empty
// runs.

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

fn unused_let(x: int32) -> int32 {
    let unused: int32 = identity(x);
    x
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
}
