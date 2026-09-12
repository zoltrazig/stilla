fn mul64(a: int64, b: int64) -> int64 { a * b }
fn sh64(x: uint64, k: uint64) -> uint64 { x >> k }
fn lt64(a: uint64, b: uint64) -> bool { a < b }
fn fmul(a: float64, b: float64) -> float64 { a * b }
fn fge(a: float64, b: float64) -> bool { a >= b }
fn b2f(x: byte) -> float64 { x as float64 }
fn i2f(x: int32) -> float64 { x as float64 }
fn u2f(x: uint32) -> float64 { x as float64 }
fn f2f(x: float32) -> float64 { x as float64 }
fn f2i(x: float64) -> int32 { x as int32 }
fn main() -> int32 {
    let a: int64 = 9223372036854775807;
    let b: uint64 = 18446744073709551615;
    let c: float64 = 3.141592653589793;
    let d = mul64(a, a);
    let e = sh64(b, b);
    let g = fmul(c, c);
    let h = f2i(g);
    0
}
