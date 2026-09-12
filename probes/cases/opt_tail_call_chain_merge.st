fn f(n: int32) -> int32 {
    if (n <= 0) {
        0
    } else if (n == 1) {
        1
    } else {
        f(n - 1)
    }
}
fn main() -> void {}
