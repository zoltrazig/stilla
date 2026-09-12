fn f2i(a: float64) -> int32 { a as int32 }
fn f2u(a: float64) -> uint32 { a as uint32 }
fn f2b(a: float64) -> byte { a as byte }
fn f2f(a: float64) -> float32 { a as float32 }
fn i2f(a: int32) -> float64 { a as float64 }
fn u2f(a: uint32) -> float64 { a as float64 }
fn b2f(a: byte) -> float64 { a as float64 }
fn f2f32(a: float32) -> float64 { a as float64 }
fn main() -> void {
    let a: float64 = 1.0;
    f2i(a); f2u(a); f2b(a); f2f(a); i2f(1); u2f(1 as uint32);
    b2f(1 as byte); f2f32(1.0);
}
