// nested_aggregates — multi-level struct / tuple / union values that are
// destroyed. Exercises the drop-lowering expansion (hook call plus
// reverse-declaration-order field drops) recursively through nesting, and
// the union tag switch that reaches each payload's drops.

struct Leaf {
    value: int32;
    drop(leaf) {}
}

struct Node {
    left: Leaf;
    right: tuple[Leaf, Leaf];
}

union Maybe {
    leaf(Leaf), nothing
}

fn drop_node(move node: Node) -> void {
    drop node;
}

fn drop_maybe(move maybe: Maybe) -> void {
    drop maybe;
}

fn main() -> void {
    let node = Node {
        left: Leaf { value: 1 },
        right: (Leaf { value: 2 }, Leaf { value: 3 }),
    };
    drop_node(move node);
    drop_maybe(Maybe::leaf(Leaf { value: 4 }));
    drop_maybe(Maybe::nothing);
}
