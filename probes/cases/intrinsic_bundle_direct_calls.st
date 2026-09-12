const builtin = import("builtin");
const math = import("math");
const lists = import("list");
const string = import("string");
const array = import("array");
const hashmap = import("hashmap");
fn p() -> void {
    builtin.print("hi");
}
fn sq(x: float32) -> float32 { math.sqrt(x) }
fn n(xs: list[int32]) -> int32 { lists.len(xs) }
fn sl(s: str) -> int32 { string.len(s) }
fn al(borrow a: array.Array[int32]) -> int32 { array.len::[int32](a) }
fn hl(borrow m: hashmap.HashMap[int32, int32]) -> int32 { hashmap.len::[int32, int32](m) }
fn main() -> void {}
