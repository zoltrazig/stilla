const builtin = import("builtin");
const greeting: str = "hello";
fn add(a: int32, b: int32) -> int32 { a + b }
fn main() -> void { builtin.print(greeting); }
