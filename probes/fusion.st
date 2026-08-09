fn madd_i32(a: int32, b: int32, c: int32) -> int32 { a + b * c }
fn msub_i32(a: int32, b: int32, c: int32) -> int32 { a - b * c }
fn maddi_i32(a: int32, b: int32) -> int32 { a + b * 3 }

fn madd_u32(a: uint32, b: uint32, c: uint32) -> uint32 { a + b * c }
fn msub_u32(a: uint32, b: uint32, c: uint32) -> uint32 { a - b * c }
fn maddi_u32(a: uint32, b: uint32) -> uint32 {
    let k = 3 as uint32;
    a + b * k
}

fn madd_i64(a: i64, b: i64, c: i64) -> i64 { a + b * c }
fn msub_i64(a: i64, b: i64, c: i64) -> i64 { a - b * c }
fn maddi_i64(a: i64, b: i64) -> i64 {
    let k: i64 = 3;
    a + b * k
}

fn madd_u64(a: u64, b: u64, c: u64) -> u64 { a + b * c }
fn msub_u64(a: u64, b: u64, c: u64) -> u64 { a - b * c }
fn maddi_u64(a: u64, b: u64) -> u64 {
    let k: u64 = 3;
    a + b * k
}

fn madd_f32(a: float32, b: float32, c: float32) -> float32 { a + b * c }
fn msub_f32(a: float32, b: float32, c: float32) -> float32 { a - b * c }
fn madd_f64(a: f64, b: f64, c: f64) -> f64 { a + b * c }
fn msub_f64(a: f64, b: f64, c: f64) -> f64 { a - b * c }

fn main() -> void {}
