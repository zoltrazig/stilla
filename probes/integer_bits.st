fn i32_bits(a: int32, b: int32) -> tuple[int32, int32, int32, int32, int32] {
    (a << b, a >> b, a & b, a | b, a ^ b)
}

fn u32_bits(a: uint32, b: uint32) -> tuple[uint32, uint32, uint32, uint32, uint32] {
    (a << b, a >> b, a & b, a | b, a ^ b)
}

fn i64_bits(a: int64, b: int64) -> tuple[int64, int64, int64, int64, int64] {
    (a << b, a >> b, a & b, a | b, a ^ b)
}

fn u64_bits(a: uint64, b: uint64) -> tuple[uint64, uint64, uint64, uint64, uint64] {
    (a << b, a >> b, a & b, a | b, a ^ b)
}

fn main() -> void {}
