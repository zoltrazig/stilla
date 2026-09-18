// Two host reads on sibling host domains. Under the flat provider the
// domains are distinct-but-undeclared, so they conflict and the reorder
// rule (`rewrite_contract.swap_operands`) refuses the swap; under the
// `example_hierarchy` lattice they are provably disjoint and the same
// operands swap — the second instance changes the produced AIR, not just
// a legality verdict (docs/effects.md §5.7, §10.3–§10.5).
fn read(x: int32) -> int32;
fn peek(x: int32) -> int32;