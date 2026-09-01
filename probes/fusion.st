fn madd_i32(a: int32, b: int32, c: int32) -> int32 { a + b * c }
fn msub_i32(a: int32, b: int32, c: int32) -> int32 { a - b * c }
fn maddi_i32(a: int32, b: int32) -> int32 { a + b * 3 }

fn madd_u32(a: uint32, b: uint32, c: uint32) -> uint32 { a + b * c }
fn msub_u32(a: uint32, b: uint32, c: uint32) -> uint32 { a - b * c }
fn maddi_u32(a: uint32, b: uint32) -> uint32 {
    let k = 3 as uint32;
    a + b * k
}

fn madd_i64(a: int64, b: int64, c: int64) -> int64 { a + b * c }
fn msub_i64(a: int64, b: int64, c: int64) -> int64 { a - b * c }
fn maddi_i64(a: int64, b: int64) -> int64 {
    let k: int64 = 3;
    a + b * k
}

fn madd_u64(a: uint64, b: uint64, c: uint64) -> uint64 { a + b * c }
fn msub_u64(a: uint64, b: uint64, c: uint64) -> uint64 { a - b * c }
fn maddi_u64(a: uint64, b: uint64) -> uint64 {
    let k: uint64 = 3;
    a + b * k
}

fn madd_f32(a: float32, b: float32, c: float32) -> float32 { a + b * c }
fn msub_f32(a: float32, b: float32, c: float32) -> float32 { a - b * c }
fn madd_f64(a: float64, b: float64, c: float64) -> float64 { a + b * c }
fn msub_f64(a: float64, b: float64, c: float64) -> float64 { a - b * c }

fn main() -> void {}
