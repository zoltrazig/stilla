fn f(n: int32) -> int32 {
    if (n <= 0) {
        f(n)
    } else {
        f(n - 1)
    }
}
fn main() -> void {}
