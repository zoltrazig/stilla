fn countdown(n: int32) -> int32 {
    if (n == 0) {
        0
    } else {
        countdown(n - 1)
    }
}
fn main() -> void {}
