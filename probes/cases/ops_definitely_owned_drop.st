const builtin = import("builtin");
fn wrap(a: int32) -> any { a }
fn main() -> void {
    let u = wrap(1);
    let _ = u;
}
