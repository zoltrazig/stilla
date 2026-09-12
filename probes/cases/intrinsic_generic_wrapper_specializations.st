const builtin = import("builtin");
fn apply(f: fn(int32) -> str, x: int32) -> str { f(x) }
fn applyf(f: fn(float32) -> str, x: float32) -> str { f(x) }
fn main() -> void {
    apply(builtin.str::[int32], 7);
    applyf(builtin.str::[float32], 1.5);
}
