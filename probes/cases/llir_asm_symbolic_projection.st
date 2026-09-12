const builtin = import("builtin");
const magic: int32 = 12345;
const greeting: str = "hi";
fn add(a: int32, b: int32) -> int32 { a + b }
fn pick(x: int32, y: int32) -> int32 {
    if (x < y) { 1 } else { 2 }
}
fn main() -> void {
    let s = add(1, magic);
    builtin.print(greeting);
}
