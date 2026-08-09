fn i32_immediates(a: int32) -> tuple[int32, int32, int32, int32, int32, int32, int32, int32, int32, int32, bool, bool, bool, bool] {
    (a + 3, a - 3, a * 3, a / 3, a % 3, a << 3, a >> 3, a & 3, a | 3, a ^ 3, a < 3, a > 3, a == 3, a != 3)
}

fn u32_immediates(a: uint32) -> tuple[uint32, uint32, uint32, uint32, uint32, uint32, uint32, uint32, uint32, uint32, bool, bool, bool, bool] {
    let k = 3 as uint32;
    (a + k, a - k, a * k, a / k, a % k, a << k, a >> k, a & k, a | k, a ^ k, a < k, a > k, a == k, a != k)
}

fn i64_immediates(a: i64) -> tuple[i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, bool, bool, bool, bool] {
    let k: i64 = 3;
    (a + k, a - k, a * k, a / k, a % k, a << k, a >> k, a & k, a | k, a ^ k, a < k, a > k, a == k, a != k)
}

fn u64_immediates(a: u64) -> tuple[u64, u64, u64, u64, u64, u64, u64, u64, u64, u64, bool, bool, bool, bool] {
    let k: u64 = 3;
    (a + k, a - k, a * k, a / k, a % k, a << k, a >> k, a & k, a | k, a ^ k, a < k, a > k, a == k, a != k)
}

fn main() -> void {}
