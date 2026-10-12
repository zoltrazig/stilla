// Whole-pipeline AIR fixture for SEG's trivial-atom `let` duplication
// (hir.md §8.3/§8.7): the Copy atom `5` is read twice, so the `let_atom`
// rule copies the atom into each use and drops the `let`. The two uses sit
// in the two branches of one `if`, so with the rule on each arm carries its
// own `const 5`; with it off a single `const 5` stays bound in the entry
// block. That is an evaluation-count difference the AIR shows directly.
fn f(b: bool) -> int32 {
    let y = 5;
    if (b) { y } else { y }
}

fn main() -> void { }
