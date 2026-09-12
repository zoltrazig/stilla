const builtin = import("builtin");
const lists = import("list");
fn f(t: tuple[int32, str]) -> int32 { let (a, b) = t; lists.len(["x"]) }
fn main() -> void {}
