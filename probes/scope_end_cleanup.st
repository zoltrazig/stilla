// scope_end_cleanup — the scope-end destruction model (docs/effects.md
// §11.2): a source-level Unique `let` whose binding is only borrowed is
// destroyed at its enclosing block end, an owned Unique parameter is
// destroyed at normal exit, and a discarded Unique statement's
// destruction stays at its statement even when selective ANF
// materializes it into a synthesized `let`. The printing drop hook makes
// every destruction observable, so the on/off differentials compare the
// actual schedule verbatim.
const builtin = import("builtin");

struct Token {
    id: int32;
    drop(t) { builtin.print(builtin.str(t.id)); }
}

fn make(id: int32) -> Token { Token { id: id } }

// The binding is never consumed (`t.id` is a projection read): the
// scope-end destructor prints `1` before the value 1 is returned.
fn scoped() -> int32 {
    let t = make(1);
    t.id
}

// An owned Unique parameter is destroyed at normal exit: prints `2`.
fn owner(move t: Token) -> int32 { t.id }

// A moved parameter destroys nothing at the caller; `take` destroys it
// at its own exit: prints `4` inside, then 4 is returned.
fn take(move t: Token) -> int32 { t.id }

fn main() -> void {
    builtin.print(builtin.str(scoped()));
    builtin.print(builtin.str(owner(make(2))));
    // A discarded Unique statement: `--simplify` materializes it into a
    // synthesized `let`, and its destructor must fire here (prints `3`),
    // not float to the enclosing scope end.
    make(3);
    builtin.print(builtin.str(take(make(4))));
}