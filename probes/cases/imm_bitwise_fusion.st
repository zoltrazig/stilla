const builtin = import("builtin");
fn f(a: int32) -> int32 { a & 63 }
fn g(a: int32) -> int32 { a | 3 }
fn h(a: int32, b: int32) -> int32 { a ^ b }
fn k(a: int32) -> int32 { 1 | a }
fn m(a: uint32, b: uint32) -> uint32 { a ^ b }
fn n(a: int32) -> int32 { a & -2 }
fn main() -> void {
    let _ = f(1);
    let _ = g(2);
    let _ = h(4, 5);
    let _ = k(6);
    let _ = m(8 as uint32, 9 as uint32);
    let _ = n(9);
}
