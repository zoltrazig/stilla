fn msub_i32(a: int32, b: int32, c: int32) -> int32 { a - b * c }
fn msub_u32(a: uint32, b: uint32, c: uint32) -> uint32 { a - b * c }
fn msub_i64(a: int64, b: int64, c: int64) -> int64 { a - b * c }
fn msub_u64(a: uint64, b: uint64, c: uint64) -> uint64 { a - b * c }
fn msub_f32(a: float32, b: float32, c: float32) -> float32 { a - b * c }
fn msub_f64(a: float64, b: float64, c: float64) -> float64 { a - b * c }
fn rev_i32(a: int32, b: int32, c: int32) -> int32 { b * c - a }
fn multi_use(a: int32, b: int32, c: int32) -> int32 {
    let p = b * c;
    let x = a - p;
    x + p
}
fn main() -> void {
    let _ = msub_i32(9, 4, 2);
    let _ = msub_u32(9 as uint32, 4 as uint32, 2 as uint32);
    let _ = msub_i64(9, 4, 2);
    let _ = msub_u64(9 as uint64, 4 as uint64, 2 as uint64);
    let _ = msub_f32(9.0, 4.0, 2.0);
    let _ = msub_f64(9.0, 4.0, 2.0);
    let _ = rev_i32(9, 4, 2);
    let _ = multi_use(9, 4, 2);
}
