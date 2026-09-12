const builtin = import("builtin");
fn die() -> never { builtin.panic("x") }
fn f(c: bool, d: bool) -> void {
    if (c) { if (d) { die() } else { die() } } else { die() }
}
fn g(c: bool) -> void { if (c) { die() } else { die() } }
fn main() -> void {}
