const builtin = import("builtin");
fn die() -> never { builtin.panic("x") }
fn f(a: bool) -> bool { a and die() }
fn g(a: bool) -> bool { a or die() }
fn main() -> void {}
