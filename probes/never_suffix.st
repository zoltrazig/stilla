// never_suffix — the `never_returns` must fact's suffix deletion
// (docs/effects.md §10.1). `boom` is declared `void` but never returns
// (`builtin.panic`), so the effect-driven consumer deletes the now-unreachable
// statements after it while keeping the statement before it, and its
// `let`-initializer case deletes the rest of the block. The suffix after
// the normal-returning `ok` must survive untouched.

const builtin = import("builtin");

// Structurally never: declared `void`, but `builtin.panic` has no normal
// exit, so `never_returns(boom)` holds without a `-> never` signature.
fn boom() -> void { builtin.panic("boom") }

// A normal return path: never a `never_returns` fact.
fn ok() -> void { builtin.print("ok"); }

fn after_statement() -> int32 {
    builtin.print("a");
    boom();
    builtin.print("dead-statement");
    1
}

fn after_let() -> int32 {
    let x = boom();
    builtin.print("dead-let");
    2
}

fn kept() -> int32 {
    ok();
    builtin.print("kept");
    3
}

fn main() -> int32 {
    builtin.print(builtin.str(kept()));
    builtin.print(builtin.str(after_statement()));
    builtin.print(builtin.str(after_let()));
    0
}
