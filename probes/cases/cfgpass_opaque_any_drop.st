const builtin = import("builtin");
const array = import("array");
struct S { a: any; arr: array.Array[int32]; }
fn main() -> void {
    let s = S { a: 42, arr: array.make(10, 0) };
}
