const builtin = import("builtin");
fn main() -> void {
    let b = builtin.box(42);
    let y = builtin.unbox(move b);
}
