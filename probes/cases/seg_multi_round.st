// A rewrite order that needs more than one analysis/rewrite round, pinning
// the bounded-round contract (hir.md §8.2): round 1 folds the constant `if`
// condition, overwriting that operand node in place; the parent's CSE pass
// then sees the just-rewritten operand as dirty and refuses it, so the
// sharing is only found once a fresh round re-analyzes the tree.
fn share_after_fold(x: int32) -> int32 { (if (true) { x * x } else { 0 }) + (x * x) }
fn main() -> void { }
