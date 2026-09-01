fn i32_ops(a: int32, b: int32) -> tuple[int32, int32, int32, int32, int32, int32] {
    (a + b, a - b, a * b, a / b, a % b, -a)
}

fn u32_ops(a: uint32, b: uint32) -> tuple[uint32, uint32, uint32, uint32, uint32, uint32] {
    (a + b, a - b, a * b, a / b, a % b, -a)
}

fn i64_ops(a: int64, b: int64) -> tuple[int64, int64, int64, int64, int64, int64] {
    (a + b, a - b, a * b, a / b, a % b, -a)
}

fn u64_ops(a: uint64, b: uint64) -> tuple[uint64, uint64, uint64, uint64, uint64, uint64] {
    (a + b, a - b, a * b, a / b, a % b, -a)
}

fn f32_ops(a: float32, b: float32) -> tuple[float32, float32, float32, float32, float32, float32] {
    (a + b, a - b, a * b, a / b, a % b, -a)
}

fn f64_ops(a: float64, b: float64) -> tuple[float64, float64, float64, float64, float64, float64] {
    (a + b, a - b, a * b, a / b, a % b, -a)
}

fn main() -> void {}
