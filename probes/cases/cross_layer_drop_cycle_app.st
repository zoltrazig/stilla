// cross_layer_drop_cycle_app — the precision gain of the unified
// EffectDependencyNode graph made observable (docs/effects.md §11.1).
//
// `f` destroys a `T` (cleanup token edge `f → drop_type(T)`), whose hook
// calls `f` (`drop_type → function`), and `f` also reads host(2). The old
// cross-layer fallback made `f` `Top` (wildcard accesses); the unified
// fixpoint resolves the cycle to the precise `read(host2) + MayDiverge`.
//
// `h` writes the two reads as `peek + read` (host(3) then host(2)). Under
// `example_hierarchy` (host(2)/host(3) are disjoint sibling sub-trees) the
// `reorder` rule swaps them into canonical order — but only because `f`'s
// summary is precise: `Top`'s wildcard accesses are refused by
// `orderCompatible` even under the hierarchy instance. Under the flat
// provider the two undeclared domains conflict, so no swap.
//
// `main` is never executed by the compiling test (the cycle diverges), it
// only keeps `h` source-reachable for the island walk.

const hostmod = import("cross_layer_host");

struct T {
    id: int32;
    drop(t) {
        f(t.id);
    }
}

fn f(id: int32) -> int32 {
    let t = T { id: id };
    hostmod.read(id)
}

fn g(id: int32) -> int32 {
    hostmod.peek(id)
}

fn h(id: int32) -> int32 {
    g(id) + f(id)
}

fn main() -> int32 {
    let _: int32 = h(1);
    0
}
