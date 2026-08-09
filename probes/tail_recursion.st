fn sum(n: int32, acc: int32) -> int32 {
    if (n == 0) { acc } else { sum(n - 1, acc + n) }
}

fn main() -> void {
    let _ = sum(10, 0);
}
