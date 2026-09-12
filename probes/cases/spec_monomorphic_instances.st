const iter = import("iter");
const lists = import("list");
const builtin = import("builtin");
fn main() -> int32 {
    iter.fold(lists.range(1, 10), 0, fn(move a: int32, borrow x: int32) -> int32 { a + x })
}
