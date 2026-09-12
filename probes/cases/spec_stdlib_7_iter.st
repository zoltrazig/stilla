const iter = import("iter");
const lists = import("list");
const builtin = import("builtin");
fn main() -> void {
    let total = iter.fold(
        lists.range(1, 10),
        0,
        fn(move acc: int32, borrow x: int32) -> int32 { acc + x }
    );
    builtin.print(builtin.str(total));
}
