const builtin = import("builtin");
const greeting: str = "hello";
fn add(a: int32, b: int32) -> int32 { a + b }
fn main() -> void {
    let s = greeting;
    let x = add(1, 2);
    builtin.print(s);
}
