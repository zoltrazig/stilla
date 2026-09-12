const dep = import("dep");
const builtin = import("builtin");
struct U0 {
    x: int32;
    y: int32;
    drop(u) {
        builtin.assert((u.x) == (u.y), "uok");
    }
}
fn apply(g: fn(int32) -> int32, v: int32) -> int32 { g(v) }
fn main() -> void {
    let u: U0 = U0 { x: 1, y: 1 };
    let d = dep.f(1);
    let r = apply(fn(a: int32) -> int32 { a + 1 }, d);
    builtin.assert(r == 3, "r");
    drop u;
}
