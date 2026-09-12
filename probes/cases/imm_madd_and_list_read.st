const builtin = import("builtin");
const lists = import("list");
fn poly(x: int32, y: int32, c: int32) -> int32 { x * y + c }
fn sink(v: int32) -> int32 { v }
fn via_call(x: int32, y: int32, c: int32) -> int32 { sink(x * y + c) }
fn scale(x: int32, c: int32) -> int32 { x * 2 + c }
fn acc(c: float32, x: float32, y: float32) -> float32 { c + x * y }
fn first(xs: list[int32]) -> int32 {
    match (xs) {
        [] => 0,
        [h, ..t] => h,
    }
}
fn main() -> void {
    let _ = poly(3, 4, 1);
    let _ = via_call(3, 4, 1);
    let _ = scale(5, 1);
    let _ = acc(1.0, 2.0, 3.0);
    let _ = first(lists.range(0, 3));
}
