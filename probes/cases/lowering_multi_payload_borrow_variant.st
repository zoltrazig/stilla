const builtin = import("builtin");
union Tree[T] {
    Empty,
    Node(box[Tree[T]], T, box[Tree[T]])
}
struct Nothing {}
fn sum(t: Tree[int32]) -> int32 {
    match (t) {
        Tree::Empty => 0,
        Tree::Node(l, x, r) => x,
    }
}
fn main() -> void { let n = Nothing{}; let _ = n; }
