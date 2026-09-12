const builtin = import("builtin");
const iter = import("iter");
using iter.Result;
fn over(move a: int32, borrow x: int32) -> iter.Result[int32, str] {
    if (a + x > 10) { Result::Break("stop") } else { Result::Complete(a + x) }
}
fn run(xs: list[int32]) -> void {
    let r = iter.try_fold(xs, 0, over);
    match (r) {
        Result::Complete(v) => builtin.print(builtin.str(v)),
        Result::Break(m) => builtin.print(m)
    }
}
fn main() -> void { builtin.print("x"); }
