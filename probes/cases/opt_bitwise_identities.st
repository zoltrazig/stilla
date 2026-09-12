const builtin = import("builtin");
fn f(a: int32) -> int32 { a | 0 }
fn g(a: int32) -> int32 { 0 ^ a }
fn h(a: int32) -> int32 { a & 0 }
fn main() -> void {
    let _ = f(1);
    let _ = g(2);
    let _ = h(3);
}
