const builtin = import("builtin");
fn eff(x: int32) -> void { (fn(a: int32) -> void { builtin.print("hi") })(x) }
fn main() -> void { }
