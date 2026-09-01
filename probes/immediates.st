fn i32_immediates(a: int32) -> tuple[int32, int32, int32, int32, int32, int32, int32, int32, int32, int32, bool, bool, bool, bool] {
    (a + 3, a - 3, a * 3, a / 3, a % 3, a << 3, a >> 3, a & 3, a | 3, a ^ 3, a < 3, a > 3, a == 3, a != 3)
}

fn u32_immediates(a: uint32) -> tuple[uint32, uint32, uint32, uint32, uint32, uint32, uint32, uint32, uint32, uint32, bool, bool, bool, bool] {
    let k = 3 as uint32;
    (a + k, a - k, a * k, a / k, a % k, a << k, a >> k, a & k, a | k, a ^ k, a < k, a > k, a == k, a != k)
}

fn i64_immediates(a: int64) -> tuple[int64, int64, int64, int64, int64, int64, int64, int64, int64, int64, bool, bool, bool, bool] {
    let k: int64 = 3;
    (a + k, a - k, a * k, a / k, a % k, a << k, a >> k, a & k, a | k, a ^ k, a < k, a > k, a == k, a != k)
}

fn u64_immediates(a: uint64) -> tuple[uint64, uint64, uint64, uint64, uint64, uint64, uint64, uint64, uint64, uint64, bool, bool, bool, bool] {
    let k: uint64 = 3;
    (a + k, a - k, a * k, a / k, a % k, a << k, a >> k, a & k, a | k, a ^ k, a < k, a > k, a == k, a != k)
}

fn main() -> void {}
