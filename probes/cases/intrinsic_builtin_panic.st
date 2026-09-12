const builtin = import("builtin");
fn die(msg: str) -> never {
    builtin.panic(msg)
}
fn main() -> void {}
