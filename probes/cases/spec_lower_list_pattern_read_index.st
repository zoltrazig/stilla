const lists = import("list");
fn f(xs: list[int32]) -> int32 {
    match (xs) {
        [] => 0,
        [h, ..t] => h,
    }
}
fn main() -> void {}
