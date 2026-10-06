// recursive_drop — a self-recursive nominal type whose only cycle passes
// through `box` (cfg-lowering.md "Destruction placement", optimizer.md
// "Drop lowering (post-optimization)"). `Tree`'s `Node` variant boxes
// another `Tree`, so the structural drop expansion has no finite form:
// re-entering `Tree` while it is being expanded emits a residual `drop`
// for the boxed component, and the runtime destroys that component
// through its type metadata (Runtime §6.3). The printing `Leaf` drop hook
// makes every leaf destruction observable, so a lost residual drop (or a
// return to unbounded compile-time recursion) changes the output.
//
// `root` nests three levels: a `Node` over a boxed `Node` over two boxed
// `Leaf`s, plus a third boxed `Leaf`. The outer union drop is expanded in
// the CFG (the `Leaf` arm calls its hook); each boxed `Tree` is the cycle
// edge, so its destruction stays a residual `drop` that the runtime
// expands — the walker must release every owned counted child it meets,
// one level deeper per nesting. The program is deterministic and returns
// normally — a runnable corpus member, not a panic.

const builtin = import("builtin");

struct Leaf {
    value: int32;
    drop(leaf) { builtin.print(builtin.str(leaf.value)); }
}

union Tree {
    Leaf(Leaf),
    Node(box[Tree], box[Tree])
}

fn leaf(value: int32) -> Tree { Tree::Leaf(Leaf { value: value }) }

fn main() -> void {
    let l1 = leaf(1);
    let l2 = leaf(2);
    let mid = Tree::Node(builtin.box::[Tree](move l1), builtin.box::[Tree](move l2));
    let l3 = leaf(3);
    let root = Tree::Node(builtin.box::[Tree](move mid), builtin.box::[Tree](move l3));
    drop root;
}
