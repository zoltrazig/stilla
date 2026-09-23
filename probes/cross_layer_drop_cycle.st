// cross_layer_drop_cycle — the unified EffectDependencyNode graph
// (docs/effects.md §11.1). `T`'s `drop` hook calls `f`, and `f`'s body
// destroys a `T` through a cleanup token, so the dependency graph carries
// the cross-layer cycle `f → drop_type(T) → hook → f`. Before
// unification the missing cleanup-token edge left `f` outside the hook's
// SCC, so its summary could fall back to `Top`; the unified fixpoint
// resolves the SCC to a precise `Diverge` (a parameterized function
// recursion that cannot be proven total).
//
// The hook recurses only while `t.id > 0`, so execution terminates and
// the printed value is fixed — the probe is a runnable corpus member,
// not an intentional panic.

const builtin = import("builtin");

struct T {
    id: int32;
    drop(t) {
        if (t.id > 0) {
            f(t.id - 1);
        }
    }
}

fn f(id: int32) -> int32 {
    let t = T { id: id };
    id
}

fn main() -> int32 {
    builtin.print(builtin.str(f(3)));
    0
}
