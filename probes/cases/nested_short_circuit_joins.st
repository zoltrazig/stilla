const builtin = import("builtin");
fn die() -> never { builtin.panic("x") }
fn f(a: bool, b: bool, c: bool) -> bool { a and (b and c) }
fn g(a: bool, b: bool) -> bool { a and (b or die()) }
fn main() -> void {}
