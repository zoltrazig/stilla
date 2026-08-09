fn i32_bits(a: int32, b: int32) -> tuple[int32, int32, int32, int32, int32] {
    (a << b, a >> b, a & b, a | b, a ^ b)
}

fn u32_bits(a: uint32, b: uint32) -> tuple[uint32, uint32, uint32, uint32, uint32] {
    (a << b, a >> b, a & b, a | b, a ^ b)
}

fn i64_bits(a: i64, b: i64) -> tuple[i64, i64, i64, i64, i64] {
    (a << b, a >> b, a & b, a | b, a ^ b)
}

fn u64_bits(a: u64, b: u64) -> tuple[u64, u64, u64, u64, u64] {
    (a << b, a >> b, a & b, a | b, a ^ b)
}

fn main() -> void {}
