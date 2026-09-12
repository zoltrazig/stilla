fn i32gt(a: int32, b: int32) -> bool { a > b }
fn i32le(a: int32, b: int32) -> bool { a <= b }
fn f64gt(a: float64, b: float64) -> bool { a > b }
fn f64le(a: float64, b: float64) -> bool { a <= b }
fn main() -> void {
    let a: int32 = 1; let e: float64 = 1.0;
    i32gt(a, a); i32le(a, a); f64gt(e, e); f64le(e, e);
}
