// CSE sharing (hir.md §8.3): two α-equivalent, `isDuplicable` operands of
// one `strict_ltr`, region-free island node are computed once and read
// from a synthesized `let`.
fn mul_pair(x: int32, y: int32) -> int32 { (x * y) + (x * y) }
fn main() -> void { }
