const builtin = import("builtin");
fn die(f: fn(str) -> never, s: str) -> never { f(s) }
fn main() -> void {
    let p = builtin.panic;
}
