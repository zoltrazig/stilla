const builtin = import("builtin");
fn f(a: int32) -> int32 { a + 2 }
fn g(a: int32) -> int32 { if (3 < a) { 1 } else { 0 } }
fn k(a: float32) -> float32 { a * 2.5 }
fn main() -> void {
    let _ = f(1);
    let _ = g(2);
    let _ = k(4.0);
}
