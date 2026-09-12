fn i32eq(a: int32, b: int32) -> bool { a == b }
fn i32ne(a: int32, b: int32) -> bool { a != b }
fn i32lt(a: int32, b: int32) -> bool { a < b }
fn i32ge(a: int32, b: int32) -> bool { a >= b }
fn u32eq(a: uint32, b: uint32) -> bool { a == b }
fn u32ne(a: uint32, b: uint32) -> bool { a != b }
fn u32lt(a: uint32, b: uint32) -> bool { a < b }
fn u32ge(a: uint32, b: uint32) -> bool { a >= b }
fn i64eq(a: int64, b: int64) -> bool { a == b }
fn i64ne(a: int64, b: int64) -> bool { a != b }
fn i64lt(a: int64, b: int64) -> bool { a < b }
fn i64ge(a: int64, b: int64) -> bool { a >= b }
fn u64eq(a: uint64, b: uint64) -> bool { a == b }
fn u64ne(a: uint64, b: uint64) -> bool { a != b }
fn u64lt(a: uint64, b: uint64) -> bool { a < b }
fn u64ge(a: uint64, b: uint64) -> bool { a >= b }
fn f32eq(a: float32, b: float32) -> bool { a == b }
fn f32ne(a: float32, b: float32) -> bool { a != b }
fn f32lt(a: float32, b: float32) -> bool { a < b }
fn f32ge(a: float32, b: float32) -> bool { a >= b }
fn f64eq(a: float64, b: float64) -> bool { a == b }
fn f64ne(a: float64, b: float64) -> bool { a != b }
fn f64lt(a: float64, b: float64) -> bool { a < b }
fn f64ge(a: float64, b: float64) -> bool { a >= b }
fn main() -> void {
    let a: int32 = 1; let b: uint32 = 1 as uint32; let c: int64 = 1; let d: uint64 = 1;
    let e: float32 = 1.0; let f: float64 = 1.0;
    i32eq(a, a); i32ne(a, a); i32lt(a, a); i32ge(a, a);
    u32eq(b, b); u32ne(b, b); u32lt(b, b); u32ge(b, b);
    i64eq(c, c); i64ne(c, c); i64lt(c, c); i64ge(c, c);
    u64eq(d, d); u64ne(d, d); u64lt(d, d); u64ge(d, d);
    f32eq(e, e); f32ne(e, e); f32lt(e, e); f32ge(e, e);
    f64eq(f, f); f64ne(f, f); f64lt(f, f); f64ge(f, f);
}
