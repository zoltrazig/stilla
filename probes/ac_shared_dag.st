// ac_shared_dag — the DAG-safe AC canonicalization past the old
// `max_ac_leaves = 32` flatten budget (hir.md §8.2). A CSE-shared chain of
// 32 `(a + b)` terms: every term is textually identical, so the e-graph
// hash-conses them into one class and the AC chain is a DAG, not a tree. Its
// flattened leaf multiset is 64 occurrences (32 `a` + 32 `b`), twice the old
// 32-leaf budget, so the deleted `flattenAc` walk would have exceeded the cap
// and left the node uncanonicalized. The memoized `Bag` instead collapses
// the whole DAG to the two entries `(a, 32)` and `(b, 32)`, and
// `buildRun` / `buildCanonical` materialize the canonical chain in O(log
// count) new e-nodes per run — no `2^k` flatten. Extraction's cost model
// selects that canonical form, so the AIR changes.
//
// The source association is deliberately non-canonical: a left-associative
// `((((a + b) + (a + b)) + (a + b)) + …)`, whereas the canonical `acRep`
// order groups the two runs by leaf (`a`s first, then `b`s). With
// `egraph_ac` on the AIR is the canonical grouped chain; with it off the AIR
// keeps the source left-deep chain over the one shared `a + b` class. The
// regroup is value-preserving, so `main` prints the same value either way —
// the real differential is the AIR (`--opt`/`--no-opt egraph_ac`), not the
// runtime output. The whole DAG has to be written out as source: a
// source-level `let` would open its own full-expression boundary and keep
// the shared term out of the island, so the arena would never see the DAG.

const builtin = import("builtin");

fn ac_shared_dag(a: int32, b: int32) -> int32 {
    (a + b)
    + (a + b)
    + (a + b)
    + (a + b)
    + (a + b)
    + (a + b)
    + (a + b)
    + (a + b)
    + (a + b)
    + (a + b)
    + (a + b)
    + (a + b)
    + (a + b)
    + (a + b)
    + (a + b)
    + (a + b)
    + (a + b)
    + (a + b)
    + (a + b)
    + (a + b)
    + (a + b)
    + (a + b)
    + (a + b)
    + (a + b)
    + (a + b)
    + (a + b)
    + (a + b)
    + (a + b)
    + (a + b)
    + (a + b)
    + (a + b)
    + (a + b)
}

fn main() -> void {
    builtin.print(builtin.str(ac_shared_dag(2, 3)));
}
