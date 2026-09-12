const builtin = import("builtin");
fn pick(a: int32, b: int32) -> int32 {
    if (a < b) { a } else { b }
}
struct P { x: int32; }
fn pick_field(c: bool, borrow p1: P, borrow p2: P) -> int32 {
    let v = if (c) { p1 } else { p2 };
    v.x
}
fn main() -> void {
    let x = pick(1, 2);
    builtin.print(builtin.str(x));
}
