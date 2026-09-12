// effectful_beta — SEG's β rule admits effectful arguments
// (docs/effects.md §10.4): β→let evaluates each argument exactly once in
// left-to-right order and never deletes, duplicates, or reorders it, so an
// argument that prints must keep its observable effect and its position.
// Every helper prints from an argument position and `main` prints each
// result, so the SEG on/off differential compares the effect order, not
// just the values.

const builtin = import("builtin");

fn shout(tag: int32) -> int32 {
    builtin.print(builtin.str(tag));
    tag
}

// Two effectful arguments: `shout(1)` must stay before `shout(2)`, so the
// differential prints 1, 2, 21. The body reads `a` (bound first) after
// `b`, so forwarding the first init to its use point would evaluate
// `shout(1)` after `shout(2)` and print 2, 1, 21.
fn ordered() -> int32 {
    (fn(a: int32, b: int32) -> int32 { b * 10 + a })(shout(1), shout(2))
}

// The parameter is read twice: the argument's effect happens once, at the
// β-generated let.
fn doubled() -> int32 {
    (fn(a: int32) -> int32 { a + a })(shout(3))
}

// The parameter is read once — forwarding the init to the use point would
// move the effect, so the let survives.
fn once() -> int32 {
    (fn(a: int32) -> int32 { a + 1 })(shout(4))
}

// The parameter is never read — dead-let would drop the effect, so the let
// survives.
fn unused() -> int32 {
    (fn(a: int32) -> int32 { 9 })(shout(5))
}

fn main() -> void {
    builtin.print(builtin.str(ordered()));
    builtin.print(builtin.str(doubled()));
    builtin.print(builtin.str(once()));
    builtin.print(builtin.str(unused()));
}
