const builtin = import("builtin");
const iter = import("iter");
using iter.Result;
fn run(xs: list[int32]) -> void {
    let r = iter.try_fold_with::[int32, int32, int32, void](
        xs, 0, (),
        fn(move acc: int32, borrow ctx: void, borrow x: int32) -> Result[int32, int32] {
            if (acc + x > 10) { Result::Break(acc) } else { Result::Complete(acc + x) }
        }
    );
}
fn main() -> void { builtin.print("x"); }
