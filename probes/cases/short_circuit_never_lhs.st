const builtin = import("builtin");
fn die() -> never { builtin.panic("x") }
fn f(a: bool) -> bool { die() and a }
fn g(a: bool) -> bool { die() or a }
fn main() -> void {}
