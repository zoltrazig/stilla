const builtin = import("builtin");
fn f() -> int32 { 6 << 2 }
fn g() -> int32 { -16 >> 2 }
fn h() -> int32 { 1 << 33 }
fn k() -> int32 { -1 << -1 }
fn main() -> void {
    let _ = f();
    let _ = g();
    let _ = h();
    let _ = k();
}
