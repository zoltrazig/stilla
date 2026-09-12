const builtin = import("builtin");
fn g(ctx: void) -> int32 { 7 }
fn mid(x: int32, ctx: void, y: int32) -> int32 { x + y }
fn main() -> void {
    let a = g(());
    let b = mid(1, (), 2);
    builtin.assert(a + b == 10, "void args");
}
