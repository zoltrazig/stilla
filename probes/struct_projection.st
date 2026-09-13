// struct_projection — SEG's struct projection rule (hir.md §8.3):
// `field_get(struct_make(v0, …, vn), i) → vi` at a known field index. A
// declaration-ordered constructor is a bare `struct_make` in the field
// read's own full expression, so the projection folds for every index;
// the projected operand may be any island subtree, not just a literal.
// The refused shapes sit here too: a `let`-bound base (not a constructor,
// so no rule) and an out-of-declaration-order literal (the builder's temp
// `let` chain opens a full-expression boundary, so the read never sees a
// bare `struct_make` — hir.md §5.6/§8.7). `main` prints every result so
// the SEG on/off differential compares observable output.

const builtin = import("builtin");

struct Triple {
    a: int32;
    b: int32;
    c: int32;
}

// Declaration order: each field read folds to its own constructor operand.
fn project_first() -> int32 { Triple { a: 10, b: 20, c: 30 }.a }
fn project_second() -> int32 { Triple { a: 10, b: 20, c: 30 }.b }
fn project_third() -> int32 { Triple { a: 10, b: 20, c: 30 }.c }

// The projected operand is a non-constant island subtree; projection drops
// the constructor and keeps that operand's expression.
fn project_expr(x: int32) -> int32 { Triple { a: x + 1, b: 2, c: 3 }.a }

// A binding base is not a constructor: no rule fires and the field read
// survives unchanged.
fn project_binding(t: Triple) -> int32 { t.b }

// Written out of declaration order: the builder's temp `let` chain puts
// each value in its own full expression, so no bare `struct_make` remains
// under the read.
fn project_permuted() -> int32 { Triple { c: 30, a: 10, b: 20 }.b }

fn main() -> void {
    builtin.print(builtin.str(project_first()));
    builtin.print(builtin.str(project_second()));
    builtin.print(builtin.str(project_third()));
    builtin.print(builtin.str(project_expr(7)));
    builtin.print(builtin.str(project_binding(Triple { a: 1, b: 2, c: 3 })));
    builtin.print(builtin.str(project_permuted()));
}
