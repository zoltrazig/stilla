const builtin = import("builtin");
fn f(a: int32) -> int32 { a << 2 }
fn g(a: int32) -> int32 { a >> 3 }
fn j(a: int32, b: int32) -> int32 { a << b }
fn k(a: uint32, b: uint32) -> uint32 { a >> b }
fn m(a: int32) -> int32 { 2 << a }
fn main() -> void {
    let _ = f(1);
    let _ = g(2);
    let _ = j(4, 5);
    let _ = k(6 as uint32, 7 as uint32);
    let _ = m(8);
}
