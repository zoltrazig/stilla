const builtin = import("builtin");
fn main() -> int32 {
    let b = builtin.box(42);
    let n = builtin.unbox(b);
    let u = builtin.unbox(move b);
    n + u
}
