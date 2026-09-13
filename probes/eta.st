// eta — SEG's η-reduction (hir.md §8.5): a λ that only forwards its own
// parameters to a `fn_ref` callee collapses to that `fnref`. The rewrite
// is a value redirect (the λ record is untouched), so the observable
// program does not change; `main` prints every result so the SEG on/off
// differential compares real output. The refused shapes (a trapping
// callee, a local callee that captures a parameter, a swapped argument
// order) sit here so the probe runs over both sides of the gate.

const builtin = import("builtin");

fn identity(x: int32) -> int32 { x }

// A one-parameter λ wrapper over a named function: η → `fnref identity`.
fn via_lambda(v: int32) -> int32 {
    let f = fn(a: int32) -> int32 { identity(a) };
    f(v)
}

// A wrapper whose body immediately applies a second λ wrapper: the chain
// resolves to `identity` in one call.
fn via_chain(v: int32) -> int32 {
    let outer = fn(b: int32) -> int32 {
        (fn(a: int32) -> int32 { identity(a) })(b)
    };
    outer(v)
}

// `boom` may trap, so the body call is not total: η refuses and the
// wrapper survives.
fn boom(x: int32) -> int32 { 10 / x }

fn via_boom(v: int32) -> int32 {
    let f = fn(a: int32) -> int32 { boom(a) };
    f(v)
}

// The callee is a call result (`pick()(a)`), not a `fn_ref` — the case
// §8.5 keeps out (a general callee can change evaluation after
// expansion). Stilla lambdas cannot capture at all, so this is the only
// shape the capture condition can be violated by.
fn pick() -> fn(int32) -> int32 { identity }

fn via_call(v: int32) -> int32 {
    let f = fn(a: int32) -> int32 { (pick())(a) };
    f(v)
}

fn sub(a: int32, b: int32) -> int32 { a - b }

// The arguments are the wrapper's own parameters in the wrong order, so
// no η.
fn via_swap(v: int32, w: int32) -> int32 {
    let f = fn(a: int32, b: int32) -> int32 { sub(b, a) };
    f(v, w)
}

fn main() -> void {
    builtin.print(builtin.str(via_lambda(41)));
    builtin.print(builtin.str(via_chain(41)));
    builtin.print(builtin.str(via_boom(2)));
    builtin.print(builtin.str(via_call(3)));
    builtin.print(builtin.str(via_swap(9, 4)));
}
