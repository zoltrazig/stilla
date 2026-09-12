const builtin = import("builtin");
fn die() -> never { builtin.panic("x") }
fn main() -> void {
    let r = if (true) { 1 } else { die() };
}
